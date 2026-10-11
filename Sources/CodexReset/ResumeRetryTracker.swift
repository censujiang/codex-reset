import Foundation

/// Per-quota-failure retry ledger. A single original submission may be followed
/// by at most three retries, with a verification interval between submissions.
/// State survives app relaunches, avoiding an unlimited retry loop.
final class ResumeRetryTracker {
    static let maxRetries = 3
    static let maxAttempts = maxRetries + 1
    static let verificationInterval: TimeInterval = 30

    enum Decision: Equatable {
        case ready(attempt: Int)
        case wait
        case exhausted
    }

    struct Entry: Codable {
        let threadId: String
        let failedTurnId: String
        var attempts: Int
        var verifyAfter: Date
        var notifiedExhausted: Bool
    }

    private static let storageKey = "quotaResumeAttemptsV1"
    private let defaults: UserDefaults
    private var records: [Entry]
    private let capacity: Int

    init(defaults: UserDefaults = .standard, capacity: Int = 500) {
        self.defaults = defaults
        self.capacity = max(1, capacity)
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            records = Array(saved.suffix(self.capacity))
        } else {
            records = []
        }
    }

    var trackedFailures: [Entry] { records }

    func decision(threadId: String, failedTurnId: String, now: Date = Date()) -> Decision {
        guard let record = records.first(where: {
            $0.threadId == threadId && $0.failedTurnId == failedTurnId
        }) else {
            return .ready(attempt: 1)
        }
        if now < record.verifyAfter { return .wait }
        if record.attempts >= Self.maxAttempts { return .exhausted }
        return .ready(attempt: record.attempts + 1)
    }

    /// Record only an actual resume attempt. Locked-screen GUI deferrals or
    /// already-busy engine calls must not consume the retry allowance.
    @discardableResult
    func recordAttempt(threadId: String, failedTurnId: String, now: Date = Date()) -> Int {
        if let i = records.firstIndex(where: {
            $0.threadId == threadId && $0.failedTurnId == failedTurnId
        }) {
            records[i].attempts = min(records[i].attempts + 1, Self.maxAttempts)
            records[i].verifyAfter = now.addingTimeInterval(Self.verificationInterval)
            records[i].notifiedExhausted = false
            persist()
            return records[i].attempts
        }
        records.append(Entry(threadId: threadId, failedTurnId: failedTurnId,
                             attempts: 1,
                             verifyAfter: now.addingTimeInterval(Self.verificationInterval),
                             notifiedExhausted: false))
        if records.count > capacity { records.removeFirst(records.count - capacity) }
        persist()
        return 1
    }

    /// Returns true once per exhausted failure, so logs/notifications stay quiet.
    func markExhaustedNotified(threadId: String, failedTurnId: String) -> Bool {
        guard let i = records.firstIndex(where: {
            $0.threadId == threadId && $0.failedTurnId == failedTurnId
        }), records[i].attempts >= Self.maxAttempts,
              !records[i].notifiedExhausted else { return false }
        records[i].notifiedExhausted = true
        persist()
        return true
    }

    func clear(threadId: String, failedTurnId: String) {
        let old = records.count
        records.removeAll { $0.threadId == threadId && $0.failedTurnId == failedTurnId }
        if records.count != old { persist() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
