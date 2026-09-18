import Foundation

struct CodexUsageProvider: UsageProvider {
    let id = "codex"
    let displayName = "Codex"

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
            return Self.snapshot(limits: limits, tokens: tokens, failures: failures)
        }.value
    }

    static func snapshot(limits: CodexRateLimits?, tokens: CodexTokenUsage?, failures: [UsageFailure] = [], now: Date = .now) -> UsageSnapshot {
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
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            guard let date = formatter.date(from: startDate) else { return nil }
            return DailyTokenUsage(date: date, tokens: tokens)
        }
    }
}
