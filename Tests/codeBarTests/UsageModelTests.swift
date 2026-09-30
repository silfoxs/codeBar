import XCTest
@testable import codeBar

private actor ControlledUsageProvider: UsageProvider {
    nonisolated let id = "codex"
    nonisolated let displayName = "Codex"
    private var pending: CheckedContinuation<UsageSnapshot, Error>?
    private var nextResult: Result<UsageSnapshot, Error>?

    func fetchUsage() async throws -> UsageSnapshot {
        if let nextResult {
            self.nextResult = nil
            return try nextResult.get()
        }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    func resolve(_ result: Result<UsageSnapshot, Error>) {
        if let pending {
            self.pending = nil
            pending.resume(with: result)
        } else {
            nextResult = result
        }
    }
}

final class UsageModelTests: XCTestCase {
    @MainActor
    func testRefreshKeepsPreviousReadingUntilCompleteAndOnPartialFailure() async {
        let provider = ControlledUsageProvider()
        let model = UsageModel(providers: [provider])

        let firstDone = expectation(description: "first refresh")
        model.onChange = { firstDone.fulfill() }
        model.refresh()
        await provider.resolve(.success(snapshot(tokens: 100)))
        await fulfillment(of: [firstDone], timeout: 3)
        XCTAssertEqual(model.snapshots.first?.totalTokens, 100)

        let secondDone = expectation(description: "second refresh")
        model.onChange = { secondDone.fulfill() }
        model.refresh()
        XCTAssertTrue(model.isRefreshing)
        XCTAssertEqual(model.snapshots.first?.totalTokens, 100)
        await provider.resolve(.success(snapshot(tokens: 200)))
        await fulfillment(of: [secondDone], timeout: 3)
        XCTAssertEqual(model.snapshots.first?.totalTokens, 200)

        let thirdDone = expectation(description: "partial refresh")
        model.onChange = { thirdDone.fulfill() }
        model.refresh()
        await provider.resolve(.success(snapshot(tokens: nil, failures: [.invalidResponse])))
        await fulfillment(of: [thirdDone], timeout: 3)
        XCTAssertEqual(model.snapshots.first?.totalTokens, 200)
        XCTAssertNotNil(model.failures[provider.id])
    }

    private func snapshot(tokens: Int?, failures: [UsageFailure] = []) -> UsageSnapshot {
        UsageSnapshot(providerID: "codex", name: "Codex", symbol: "sparkles", windows: [],
                      resetCardExpiry: nil, resetCardCount: nil, totalTokens: tokens,
                      dailyUsage: nil, localTodayUsage: nil, spendControlReached: false,
                      fetchedAt: .now, failures: failures)
    }
}
