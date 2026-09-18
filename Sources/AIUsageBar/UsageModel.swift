import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case chinese = "中文"
    case english = "English"
    var id: String { rawValue }
}

enum RefreshInterval: Int, CaseIterable, Identifiable {
    case fastest = 10
    case fast = 30
    case standard = 60
    case slow = 180
    case verySlow = 300

    var id: Int { rawValue }
    var chineseLabel: String {
        switch self {
        case .fastest: return "极速（10 秒）"
        case .fast: return "快（30 秒）"
        case .standard: return "标准（1 分钟）"
        case .slow: return "慢（3 分钟）"
        case .verySlow: return "超慢（5 分钟）"
        }
    }
    var englishLabel: String {
        switch self {
        case .fastest: return "Fastest (10 seconds)"
        case .fast: return "Fast (30 seconds)"
        case .standard: return "Standard (1 minute)"
        case .slow: return "Slow (3 minutes)"
        case .verySlow: return "Very slow (5 minutes)"
        }
    }
}

struct UsageSnapshot: Identifiable {
    var id: String { providerID }
    let providerID: String
    let name: String
    let symbol: String
    let windows: [UsageWindow]
    let resetCardExpiry: Date?
    let resetCardCount: Int?
    let totalTokens: Int?
    let dailyUsage: [DailyTokenUsage]?
    let spendControlReached: Bool
    let fetchedAt: Date
    let failures: [UsageFailure]
    var remainingPercent: Double? { windows.map(\.remainingPercent).min() }

    func recent30DayUsage(reference: Date = .now, calendar: Calendar = .current) -> [DailyTokenUsage]? {
        guard let dailyUsage else { return nil }
        let today = calendar.startOfDay(for: reference)
        let start = calendar.date(byAdding: .day, value: -29, to: today)!
        var values: [Date: Int] = [:]
        for usage in dailyUsage {
            let date = calendar.startOfDay(for: usage.date)
            values[date, default: 0] += usage.tokens
        }
        return (0..<30).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return DailyTokenUsage(date: date, tokens: values[date] ?? 0)
        }
    }

    func recent30DayTotal(reference: Date = .now, calendar: Calendar = .current) -> Int? {
        recent30DayUsage(reference: reference, calendar: calendar)?.reduce(0) { $0 + $1.tokens }
    }
}

struct DailyTokenUsage: Identifiable, Hashable {
    let date: Date
    let tokens: Int
    var id: Date { date }
}

protocol UsageProvider {
    var id: String { get }
    var displayName: String { get }
    func fetchUsage() async throws -> UsageSnapshot
}

@MainActor
final class UsageModel: ObservableObject {
    @Published var language: AppLanguage = .chinese {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language"); onChange?() }
    }
    @Published var selectedProviderIDs: Set<String> = ["codex"] {
        didSet { UserDefaults.standard.set(Array(selectedProviderIDs), forKey: "selectedProviders"); onChange?() }
    }
    @Published var refreshInterval: RefreshInterval = .standard {
        didSet {
            UserDefaults.standard.set(refreshInterval.rawValue, forKey: "refreshInterval")
            onRefreshIntervalChange?()
        }
    }
    @Published private(set) var snapshots: [UsageSnapshot] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var failures: [String: UsageFailure] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published var hoveredBlockID: String?
    @Published private(set) var lastCompleted: Date?
    @Published private(set) var unchangedTokenProviderIDs: Set<String> = []
    private var lastAttempt: Date?
    var onChange: (() -> Void)?
    var onRefreshIntervalChange: (() -> Void)?

    let providers: [any UsageProvider]
    var visibleSnapshots: [UsageSnapshot] { snapshots.filter { selectedProviderIDs.contains($0.providerID) } }
    var primaryUsage: UsageSnapshot? { visibleSnapshots.first }
    // An incomplete aggregate is unknown, not zero or an apparently complete total.
    var totalTokens: Int? {
        let values = snapshots.compactMap(\.totalTokens)
        guard values.count == providers.count else { return nil }
        return values.reduce(0, +)
    }
    var formattedTokenTotal: String {
        guard let totalTokens else { return "—" }
        if totalTokens >= 1_000_000_000 { return String(format: "%.2fB", Double(totalTokens) / 1_000_000_000) }
        if totalTokens >= 1_000_000 { return String(format: "%.1fM", Double(totalTokens) / 1_000_000) }
        if totalTokens >= 1_000 { return String(format: "%.1fK", Double(totalTokens) / 1_000) }
        return totalTokens.formatted()
    }

    init(providers: [any UsageProvider] = [CodexUsageProvider()]) {
        self.providers = providers
        if let value = UserDefaults.standard.string(forKey: "language"), let saved = AppLanguage(rawValue: value) { language = saved }
        if let saved = UserDefaults.standard.array(forKey: "selectedProviders") as? [String] { selectedProviderIDs = Set(saved) }
        if let saved = UserDefaults.standard.object(forKey: "refreshInterval") as? Int, let interval = RefreshInterval(rawValue: saved) { refreshInterval = interval }
    }

    func refreshIfNeeded() {
        if lastAttempt == nil || Date.now.timeIntervalSince(lastAttempt!) > Double(refreshInterval.rawValue) { refresh() }
    }

    func refresh() {
        guard !isRefreshing else { return }
        AppLog.usage.debug("refresh started")
        isRefreshing = true
        lastAttempt = .now
        Task {
            var values = snapshots
            var errors: [String: UsageFailure] = [:]
            var unchanged: Set<String> = []
            for provider in providers {
                do {
                    let snapshot = try await provider.fetchUsage()
                    if let previous = values.first(where: { $0.id == provider.id }),
                       snapshot.totalTokens != nil, snapshot.totalTokens == previous.totalTokens,
                       snapshot.dailyUsage == previous.dailyUsage, snapshot.failures.isEmpty {
                        unchanged.insert(provider.id)
                    }
                    values.removeAll { $0.providerID == provider.id }
                    values.append(snapshot)
                    AppLog.usage.debug("provider refreshed: \(provider.id, privacy: .public)")
                } catch {
                    errors[provider.id] = error as? UsageFailure ?? .accountUnavailable
                    AppLog.usage.error("provider refresh failed: \(provider.id, privacy: .public)")
                }
            }
            snapshots = providers.compactMap { provider in values.first { $0.providerID == provider.id } }
            failures = errors
            unchangedTokenProviderIDs = unchanged
            lastCompleted = .now
            if errors.isEmpty && snapshots.allSatisfy({ $0.failures.isEmpty }) { lastUpdated = .now }
            isRefreshing = false
            onChange?()
        }
    }

    var refreshStatus: String {
        if isRefreshing { return text("正在刷新…", "Refreshing…") }
        if !failures.isEmpty || snapshots.contains(where: { !$0.failures.isEmpty }) {
            return text("刷新未完成", "Refresh incomplete")
        }
        return text("上次刷新", "Last checked")
    }

    var refreshTime: String {
        guard let lastCompleted else { return "—" }
        return lastCompleted.formatted(.dateTime.hour().minute().second()
            .locale(Locale(identifier: language == .chinese ? "zh_CN" : "en_US")))
    }

    func text(_ chinese: String, _ english: String) -> String { language == .chinese ? chinese : english }
    func toggle(_ providerID: String) {
        if selectedProviderIDs.contains(providerID) { selectedProviderIDs.remove(providerID) }
        else { selectedProviderIDs.insert(providerID) }
    }
    func message(_ error: UsageFailure) -> String { error.message(english: language == .english) }
    func date(_ value: Date?) -> String {
        guard let value else { return text("暂无数据", "Unavailable") }
        return value.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()
            .locale(Locale(identifier: language == .chinese ? "zh_CN" : "en_US")))
    }
}
