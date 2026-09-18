import XCTest
@testable import AIUsageBar

final class UsageProviderTests: XCTestCase {
    private func limits(_ json: String) throws -> CodexRateLimits {
        try JSONDecoder().decode(CodexRateLimits.self, from: Data(json.utf8))
    }

    func testAuthoritativeBucketAndLifetimeTokens() throws {
        let rates = try limits("""
        {"rateLimits":{"primary":{"usedPercent":99}},
         "rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":2000000000},
         "secondary":{"usedPercent":45,"windowDurationMins":10080},"spendControlReached":true}},
         "rateLimitResetCredits":{"availableCount":2,"credits":[
         {"status":"available","expiresAt":2000001000}, {"status":"available","expiresAt":2000000000},
         {"status":"expired","expiresAt":1000000000}, {"status":"consumed","expiresAt":1900000000}]}}
        """)
        let tokens = try JSONDecoder().decode(CodexTokenUsage.self, from: Data("""
        {"summary":{"lifetimeTokens":1900000001},"dailyUsageBuckets":[{"startDate":"2026-09-17","tokens":123}]}
        """.utf8))
        let snapshot = CodexUsageProvider.snapshot(limits: rates, tokens: tokens, now: Date(timeIntervalSince1970: 1800000000))
        XCTAssertEqual(snapshot.remainingPercent, 55)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.totalTokens, 1900000001) // Do not sum daily buckets on top of lifetime.
        XCTAssertEqual(snapshot.resetCardCount, 2)
        XCTAssertEqual(snapshot.resetCardExpiry?.timeIntervalSince1970, 2000000000)
        XCTAssertTrue(snapshot.spendControlReached)
        XCTAssertEqual(snapshot.recent30DayUsage(reference: Date(timeIntervalSince1970: 1790035200))?.count, 30)
    }

    func testMissingValuesAreNotZeroOrFakeDates() throws {
        let snapshot = CodexUsageProvider.snapshot(limits: try limits("{}"), tokens: nil)
        XCTAssertNil(snapshot.remainingPercent)
        XCTAssertNil(snapshot.totalTokens)
        XCTAssertNil(snapshot.resetCardExpiry)
        XCTAssertNil(snapshot.resetCardCount)
    }

    func testEmptyCreditsAndMissingDetailsDiffer() throws {
        let empty = CodexUsageProvider.snapshot(limits: try limits("""
        {"rateLimitResetCredits":{"availableCount":0,"credits":[]}}
        """), tokens: nil)
        let missing = CodexUsageProvider.snapshot(limits: try limits("""
        {"rateLimitResetCredits":{"availableCount":2,"credits":null}}
        """), tokens: nil)
        XCTAssertEqual(empty.resetCardCount, 0)
        XCTAssertEqual(missing.resetCardCount, 2)
        XCTAssertNil(empty.resetCardExpiry)
        XCTAssertNil(missing.resetCardExpiry)
    }

    func testMapDoesNotFallBackToDifferentProduct() throws {
        let snapshot = CodexUsageProvider.snapshot(limits: try limits("""
        {"rateLimits":{"primary":{"usedPercent":80}},"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":20}}}}
        """), tokens: nil)
        XCTAssertNil(snapshot.remainingPercent)
    }

    func testLegacyWindowAndClamping() throws {
        let snapshot = CodexUsageProvider.snapshot(limits: try limits("""
        {"rateLimits":{"primary":{"usedPercent":150},"secondary":{"usedPercent":-5}}}
        """), tokens: nil)
        XCTAssertEqual(snapshot.windows.map(\.remainingPercent), [0, 100])
    }

    func testRecentThirtyDayTotalUsesDailyBucketsOnly() throws {
        let tokens = try JSONDecoder().decode(CodexTokenUsage.self, from: Data("""
        {"summary":{"lifetimeTokens":999999},"dailyUsageBuckets":[
          {"startDate":"2026-09-17","tokens":100},
          {"startDate":"2026-09-01","tokens":250},
          {"startDate":"2026-08-01","tokens":9999}
        ]}
        """.utf8))
        let snapshot = CodexUsageProvider.snapshot(limits: nil, tokens: tokens, now: ISO8601DateFormatter().date(from: "2026-09-18T00:00:00Z")!)
        XCTAssertEqual(snapshot.recent30DayTotal(reference: ISO8601DateFormatter().date(from: "2026-09-18T00:00:00Z")!), 350)
    }
}
