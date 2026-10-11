import XCTest
import SQLite3
@testable import CodexReset

final class ResumeSafetyTests: XCTestCase {
    func testOnlyLatestUsageLimitFailureIsEligible() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try executeSQL(at: home.appendingPathComponent("thread_history_1.sqlite"), """
            CREATE TABLE thread_turns (thread_id TEXT, turn_id TEXT, status TEXT, error_json TEXT, started_at INTEGER);
            INSERT INTO thread_turns VALUES ('finished', '001', 'failed', 'usageLimitExceeded', 1);
            INSERT INTO thread_turns VALUES ('finished', '002', 'completed', NULL, 2);
            INSERT INTO thread_turns VALUES ('still-paused', '003', 'failed', 'usageLimitExceeded', 3);
            INSERT INTO thread_turns VALUES ('other-error', '004', 'failed', 'usageLimitExceeded', 4);
            INSERT INTO thread_turns VALUES ('other-error', '005', 'failed', 'networkUnavailable', 5);
            INSERT INTO thread_turns VALUES ('paused-again', '006', 'completed', NULL, 6);
            INSERT INTO thread_turns VALUES ('paused-again', '007', 'failed', 'usageLimitExceeded', 7);
            """)
        try executeSQL(at: home.appendingPathComponent("state_5.sqlite"), """
            CREATE TABLE threads (id TEXT, title TEXT, cwd TEXT, source TEXT, archived INTEGER, updated_at INTEGER, updated_at_ms INTEGER);
            INSERT INTO threads VALUES ('finished', 'Finished task', '/tmp', 'user', 0, 2, 2);
            INSERT INTO threads VALUES ('still-paused', 'Paused task', '/tmp', 'user', 0, 3, 3);
            INSERT INTO threads VALUES ('other-error', 'Different failure', '/tmp', 'user', 0, 5, 5);
            INSERT INTO threads VALUES ('paused-again', 'Paused again', '/tmp', 'user', 0, 7, 7);
            """)
        let paused = SQLiteReader(codexHome: home.path).usageLimitedThreads()
        XCTAssertEqual(Set(paused.map(\.threadId)), Set(["still-paused", "paused-again"]))
        XCTAssertEqual(paused.first(where: { $0.threadId == "still-paused" })?.failedTurnId, "003")
        XCTAssertEqual(paused.first(where: { $0.threadId == "paused-again" })?.failedTurnId, "007")
    }

    func testHandledFailuresPersistAndNewFailuresRemainEligible() {
        let suite = "CodexResetTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Unable to create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = HandledFailures(defaults: defaults, maxEntries: 2)
        XCTAssertFalse(first.contains(threadId: "t", failedTurnId: "f1"))
        first.record(threadId: "t", failedTurnId: "f1")
        XCTAssertTrue(first.contains(threadId: "t", failedTurnId: "f1"))
        XCTAssertFalse(first.contains(threadId: "t", failedTurnId: "f2"))
        let relaunched = HandledFailures(defaults: defaults, maxEntries: 2)
        XCTAssertTrue(relaunched.contains(threadId: "t", failedTurnId: "f1"))
        relaunched.record(threadId: "t", failedTurnId: "f2")
        XCTAssertTrue(relaunched.contains(threadId: "t", failedTurnId: "f2"))
        relaunched.record(threadId: "other", failedTurnId: "f3")
        XCTAssertFalse(relaunched.contains(threadId: "t", failedTurnId: "f1"))
    }

    func testIdleSleepProtectionOnlyForOptedInSelectedWork() {
        func check(_ enabled: Bool, _ auto: Bool, _ pending: Bool, _ running: Bool, _ sending: Bool = false) -> Bool {
            IdleSleepPolicy.shouldPreventIdleSleep(
                enabled: enabled,
                autoContinueEnabled: auto,
                hasSelectedQuotaFailure: pending,
                hasSelectedRunningTurn: running,
                isSendingContinue: sending
            )
        }
        XCTAssertFalse(check(false, true, true, false))
        XCTAssertFalse(check(true, false, true, false))
        XCTAssertFalse(check(true, true, false, false))
        XCTAssertTrue(check(true, true, true, false))
        XCTAssertTrue(check(true, true, false, true))
        XCTAssertTrue(check(true, true, false, false, true))
        // All selected turns finished: the assertion must be released.
        XCTAssertFalse(check(true, true, false, false))
    }

    func testActiveTurnDetectionUsesLatestTurnPerSelectedThread() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try executeSQL(at: home.appendingPathComponent("thread_history_1.sqlite"), """
            CREATE TABLE thread_turns (thread_id TEXT, turn_id TEXT, status TEXT, error_json TEXT, started_at INTEGER);
            INSERT INTO thread_turns VALUES ('finished', '001', 'inProgress', NULL, 1);
            INSERT INTO thread_turns VALUES ('finished', '002', 'completed', NULL, 2);
            INSERT INTO thread_turns VALUES ('working', '003', 'inProgress', NULL, 3);
            INSERT INTO thread_turns VALUES ('queued', '004', 'queued', NULL, 4);
            INSERT INTO thread_turns VALUES ('failed', '005', 'failed', 'usageLimitExceeded', 5);
            """)
        let reader = SQLiteReader(codexHome: home.path)
        XCTAssertEqual(reader.activeThreadIds(for: ["finished", "working", "queued", "failed"]),
                       Set(["working", "queued"]))
        XCTAssertEqual(reader.activeThreadIds(for: ["finished"]), [])
        XCTAssertEqual(reader.activeThreadIds(for: []), [])
    }

    func testExperimentalScreenLockProtectionIsOptInAndRespectsLock() {
        XCTAssertFalse(ScreenLockPreventionPolicy.shouldKeepDisplayAwake(
            enabled: false, workPending: true, locked: false
        ))
        XCTAssertFalse(ScreenLockPreventionPolicy.shouldKeepDisplayAwake(
            enabled: true, workPending: false, locked: false
        ))
        XCTAssertFalse(ScreenLockPreventionPolicy.shouldKeepDisplayAwake(
            enabled: true, workPending: true, locked: true
        ))
        XCTAssertTrue(ScreenLockPreventionPolicy.shouldKeepDisplayAwake(
            enabled: true, workPending: true, locked: false
        ))
    }

    func testGUIConfirmationRequiresANewerPersistedTurn() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let dbPath = home.appendingPathComponent("thread_history_1.sqlite")
        try executeSQL(at: dbPath, """
            CREATE TABLE thread_turns (thread_id TEXT, turn_id TEXT, status TEXT, error_json TEXT, started_at INTEGER);
            INSERT INTO thread_turns VALUES ('thread-a', '001', 'failed', 'usageLimitExceeded', 1);
            INSERT INTO thread_turns VALUES ('thread-b', '003', 'completed', NULL, 3);
            """)
        let reader = SQLiteReader(codexHome: home.path)
        XCTAssertFalse(reader.hasTurnAfter(threadId: "thread-a", failedTurnId: "001"))
        XCTAssertFalse(reader.hasTurnAfter(threadId: "missing", failedTurnId: "001"))
        XCTAssertFalse(reader.hasTurnAfter(threadId: "thread-a", failedTurnId: "002"))
        try executeSQL(at: dbPath, """
            INSERT INTO thread_turns VALUES ('thread-a', '002', 'inProgress', NULL, 2);
            """)
        XCTAssertTrue(reader.hasTurnAfter(threadId: "thread-a", failedTurnId: "001"))
        XCTAssertFalse(reader.hasTurnAfter(threadId: "thread-a", failedTurnId: "002"))
    }

    func testResumeRetriesVerifyEveryThirtySecondsAndCapAtThreeRetries() {
        let suite = "CodexResetRetryTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Unable to create test defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let tracker = ResumeRetryTracker(defaults: defaults)
        let base = Date(timeIntervalSince1970: 100000)

        XCTAssertEqual(tracker.decision(threadId: "thread", failedTurnId: "limit1", now: base),
                       .ready(attempt: 1))
        for attempt in 1...ResumeRetryTracker.maxAttempts {
            let sentAt = base.addingTimeInterval(Double(attempt - 1) * 30)
            XCTAssertEqual(tracker.decision(threadId: "thread", failedTurnId: "limit1", now: sentAt),
                           .ready(attempt: attempt))
            XCTAssertEqual(tracker.recordAttempt(threadId: "thread", failedTurnId: "limit1", now: sentAt),
                           attempt)
            XCTAssertEqual(tracker.decision(threadId: "thread", failedTurnId: "limit1",
                                           now: sentAt.addingTimeInterval(29)), .wait)
        }
        let expired = base.addingTimeInterval(120)
        XCTAssertEqual(tracker.decision(threadId: "thread", failedTurnId: "limit1", now: expired),
                       .exhausted)
        XCTAssertTrue(tracker.markExhaustedNotified(threadId: "thread", failedTurnId: "limit1"))
        XCTAssertFalse(tracker.markExhaustedNotified(threadId: "thread", failedTurnId: "limit1"))

        let relaunched = ResumeRetryTracker(defaults: defaults)
        XCTAssertEqual(relaunched.decision(threadId: "thread", failedTurnId: "limit1", now: expired),
                       .exhausted)
        XCTAssertEqual(relaunched.decision(threadId: "thread", failedTurnId: "limit2", now: expired),
                       .ready(attempt: 1))
        tracker.clear(threadId: "thread", failedTurnId: "limit1")
        XCTAssertEqual(tracker.decision(threadId: "thread", failedTurnId: "limit1", now: expired),
                       .ready(attempt: 1))
    }

    func testQuotaFailureConfirmationOnlyReturnsTrueForSameLatestFailure() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let dbPath = home.appendingPathComponent("thread_history_1.sqlite")
        try executeSQL(at: dbPath, """
            CREATE TABLE thread_turns (thread_id TEXT, turn_id TEXT, status TEXT, error_json TEXT, started_at INTEGER);
            INSERT INTO thread_turns VALUES ('thread-a', '001', 'failed', 'usageLimitExceeded', 1);
            INSERT INTO thread_turns VALUES ('thread-b', '002', 'failed', 'someOtherError', 2);
            """)
        let reader = SQLiteReader(codexHome: home.path)
        XCTAssertEqual(reader.isLatestQuotaFailure(threadId: "thread-a", failedTurnId: "001"), true)
        XCTAssertEqual(reader.isLatestQuotaFailure(threadId: "thread-b", failedTurnId: "002"), false)
        XCTAssertNil(reader.isLatestQuotaFailure(threadId: "unknown", failedTurnId: "001"))
        try executeSQL(at: dbPath, """
            INSERT INTO thread_turns VALUES ('thread-a', '003', 'inProgress', NULL, 3);
            """)
        XCTAssertEqual(reader.isLatestQuotaFailure(threadId: "thread-a", failedTurnId: "001"), false)
        XCTAssertEqual(reader.isLatestQuotaFailure(threadId: "thread-a", failedTurnId: "003"), false)
    }

    private func executeSQL(at url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw NSError(domain: "ResumeSafetyTests", code: 1)
        }
        defer { sqlite3_close(db) }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &message)
        defer { if let message { sqlite3_free(message) } }
        guard result == SQLITE_OK else {
            let details = message.map { String(cString: $0) } ?? "Unknown SQLite error"
            throw NSError(domain: "ResumeSafetyTests", code: Int(result), userInfo: [NSLocalizedDescriptionKey: details])
        }
    }
}
