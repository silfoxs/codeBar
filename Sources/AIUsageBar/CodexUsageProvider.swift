import Foundation

struct CodexUsageProvider: UsageProvider {
    let id = "codex"
    let displayName = "Codex"
    private let localReader = CodexLocalUsageReader()

    func fetchUsage() async throws -> UsageSnapshot {
        try await Task.detached(priority: .utility) {
            let client = try CodexClient()
            defer { client.close() }
            var limits: CodexRateLimits?
            var tokens: CodexTokenUsage?
            var failures: [UsageFailure] = []
            do {
                limits = try JSONDecoder().decode(CodexRateLimits.self, from: client.request("account/rateLimits/read"))
            } catch { failures.append(error as? UsageFailure ?? .invalidResponse) }
            do {
                tokens = try JSONDecoder().decode(CodexTokenUsage.self, from: client.request("account/usage/read"))
            } catch { failures.append(error as? UsageFailure ?? .invalidResponse) }
            guard limits != nil || tokens != nil else { throw failures.first ?? .accountUnavailable }
            let now = Date.now
            let hasToday = tokens?.dailyUsageBuckets?.contains {
                $0.usage.map { Calendar.current.isDate($0.date, inSameDayAs: now) } ?? false
            } == true
            let localToday = hasToday ? nil : (try? localReader.todayTokens(reference: now))
            return Self.snapshot(limits: limits, tokens: tokens, failures: failures,
                                 now: now, localTodayTokens: localToday)
        }.value
    }

    static func snapshot(limits: CodexRateLimits?, tokens: CodexTokenUsage?, failures: [UsageFailure] = [], now: Date = .now, localTodayTokens: Int? = nil) -> UsageSnapshot {
        // A map is authoritative when present; never use another product's limits.
        let rate = limits?.rateLimitsByLimitId.map { $0["codex"] } ?? limits?.rateLimits
        let windows = [rate?.primary, rate?.secondary].compactMap { $0 }
        let credits = limits?.rateLimitResetCredits
        let expiry = credits?.credits?.filter {
            $0.status == "available" && ($0.expiresAt.map { $0 > now.timeIntervalSince1970 } ?? true)
        }.compactMap(\.expiresAt).min().map { Date(timeIntervalSince1970: $0) }
        return UsageSnapshot(providerID: "codex", name: "Codex", symbol: "sparkles", windows: windows,
                             resetCardExpiry: expiry, resetCardCount: credits?.availableCount,
                             totalTokens: tokens?.summary?.lifetimeTokens,
                             dailyUsage: tokens?.dailyUsageBuckets?.compactMap { $0.usage },
                             localTodayUsage: localTodayTokens.map { DailyTokenUsage(date: Calendar.current.startOfDay(for: now), tokens: $0) },
                             spendControlReached: rate?.spendControlReached ?? false,
                             fetchedAt: now, failures: failures)
    }

}

struct CodexRateLimits: Decodable {
    let rateLimits: CodexLimit?
    let rateLimitsByLimitId: [String: CodexLimit]?
    let rateLimitResetCredits: CodexResetCredits?
}

struct CodexLimit: Decodable {
    let primary: UsageWindow?
    let secondary: UsageWindow?
    let spendControlReached: Bool?
}

struct UsageWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
    var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
    var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: $0) } }
}

struct CodexResetCredits: Decodable {
    let availableCount: Int?
    let credits: [Credit]?
    struct Credit: Decodable {
        let status: String
        let expiresAt: Double?
    }
}

struct CodexTokenUsage: Decodable {
    let summary: Summary?
    let dailyUsageBuckets: [DailyUsageBucket]?
    struct Summary: Decodable { let lifetimeTokens: Int? }
    struct DailyUsageBucket: Decodable {
        let startDate: String
        let tokens: Int

        var usage: DailyTokenUsage? {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            // A backend date label is not a UTC instant. Preserve its calendar day.
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            guard let date = formatter.date(from: startDate) else { return nil }
            return DailyTokenUsage(date: date, tokens: tokens)
        }
    }
}
