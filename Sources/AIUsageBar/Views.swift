import SwiftUI
import Charts

enum PopoverLayout {
    // Keep a real content gutter on both sides. Charts and long localized labels
    // are given this width explicitly so they cannot render under the popover edge.
    static let width: CGFloat = 360
    static let height: CGFloat = 540
    static let contentWidth: CGFloat = width - 36
}

struct UsagePopoverView: View {
    @ObservedObject var model: UsageModel
    let openSettings: () -> Void
    var body: some View {
        ZStack {
            GlassSurface(cornerRadius: 18).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AI Usage").font(.system(size: 22, weight: .bold, design: .rounded))
                        Text(model.text("账户用量", "Account usage")).foregroundStyle(.secondary).font(.subheadline)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(model.text("总 Token 消耗", "Total tokens")).font(.caption).foregroundStyle(.secondary)
                        Text(model.formattedTokenTotal).font(.system(size: 18, weight: .bold, design: .rounded))
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .help(model.totalTokensIncludingToday?.formatted() ?? model.text("暂无数据", "Unavailable"))
                    .accessibilityLabel(model.text("所有应用总 Token 消耗", "Total tokens across all apps"))
                    .accessibilityValue(model.totalTokensIncludingToday?.formatted() ?? "—")
                }
                .padding(.bottom, 12)
                
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(model.providers, id: \.id) { provider in
                            if let error = model.failures[provider.id] {
                                Label(provider.displayName + ": " + model.message(error), systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        ForEach(model.visibleSnapshots) { snapshot in
                            UsageSection(snapshot: snapshot, model: model)
                                .padding(.vertical, 4)
                        }
                        if model.selectedProviderIDs.isEmpty {
                            Text(model.text("在设置中选择要展示的应用", "Choose apps in Settings")).foregroundStyle(.secondary)
                        } else if model.snapshots.isEmpty && model.isRefreshing {
                            ProgressView(model.text("正在读取账户用量…", "Reading account usage…"))
                                .frame(maxWidth: .infinity).padding(.vertical, 32)
                        }
                    }
                    .frame(width: PopoverLayout.contentWidth, alignment: .leading)
                }
                .frame(width: PopoverLayout.contentWidth)
                HStack(spacing: 10) {
                    Button(action: model.refresh) {
                        Image(systemName: model.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isRefreshing)
                    .help(model.text("刷新", "Refresh"))
                    .accessibilityLabel(model.text("刷新", "Refresh"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.refreshStatus)
                        Text(model.refreshTime)
                    }.font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: openSettings) {
                        Label(model.text("设置", "Settings"), systemImage: "slider.horizontal.3")
                    }.buttonStyle(.borderless)
                }
                .padding(.top, 12)
                
            }
            .frame(width: PopoverLayout.contentWidth)
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
        }.frame(width: PopoverLayout.width, height: PopoverLayout.height)
    }
}

private struct UsageBlockHover: ViewModifier {
    let id: String
    @ObservedObject var model: UsageModel
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(model.hoveredBlockID == id ? (colorScheme == .dark ? 0.28 : 0.07) : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .animation(.easeOut(duration: 0.12), value: model.hoveredBlockID)
            .onHover { inside in
                if inside { model.hoveredBlockID = id }
                else if model.hoveredBlockID == id { model.hoveredBlockID = nil }
            }
    }
}

struct UsageSection: View {
    let snapshot: UsageSnapshot
    @ObservedObject var model: UsageModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(snapshot.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(snapshot.windows.enumerated()), id: \.offset) { index, window in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(windowName(window, index: index))
                        Spacer()
                        Text(String(format: "%.0f%%", window.remainingPercent)).monospacedDigit()
                    }.font(.caption)
                    ProgressView(value: window.remainingPercent, total: 100).tint(index == 0 ? quotaColor : .indigo)
                    Text(model.text("重置：", "Resets: ") + model.date(window.resetDate))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            }
            .modifier(UsageBlockHover(id: snapshot.id + "/quota", model: model))
            VStack(spacing: 10) {
            metric(model.text("可用重置卡", "Available resets"), snapshot.resetCardCount.map(String.init) ?? "—")
            metric(model.text("最早到期", "Earliest expiry"), snapshot.resetCardCount == 0 ? model.text("无", "None") : model.date(snapshot.resetCardExpiry))
            }
            .modifier(UsageBlockHover(id: snapshot.id + "/credits", model: model))
            VStack(alignment: .leading, spacing: 12) {
            metric(model.text("累计 Token", "Lifetime tokens"), snapshot.totalTokensIncludingToday?.formatted() ?? "—")
            if let today = snapshot.todayUsage() {
                metric(today.estimated ? model.text("今日 · 本地估算", "Today · local estimate") : model.text("今日 · 官方", "Today · official"), today.usage.tokens.formatted())
            } else {
                metric(model.text("今日消耗", "Today"), model.text("暂无数据", "Unavailable"))
            }
            RecentUsageChart(snapshot: snapshot, model: model)
            }
            .modifier(UsageBlockHover(id: snapshot.id + "/tokens", model: model))
            ForEach(Array(snapshot.failures.enumerated()), id: \.offset) { _, error in
                Text(model.message(error)).font(.caption).foregroundStyle(.orange)
            }
            if model.failures[snapshot.providerID] != nil {
                Text(model.text("刷新失败，以上为上次读取的数据。", "Refresh failed; showing the previous reading."))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var quotaColor: Color {
        guard let remaining = snapshot.remainingPercent else { return .secondary }
        return remaining <= 10 ? .red : remaining <= 25 ? .orange : .teal
    }

    private func windowName(_ window: UsageWindow, index: Int) -> String {
        guard let minutes = window.windowDurationMins else { return model.text("额度窗口", "Usage window") + " \(index + 1)" }
        if minutes % 1_440 == 0 { return model.text("\(minutes / 1_440) 天额度", "\(minutes / 1_440)-day quota") }
        if minutes % 60 == 0 { return model.text("\(minutes / 60) 小时额度", "\(minutes / 60)-hour quota") }
        return model.text("\(minutes) 分钟额度", "\(minutes)-minute quota")
    }
    private func metric(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).monospacedDigit()
        }.font(.caption)
    }
}

struct RecentUsageChart: View {
    let snapshot: UsageSnapshot
    @ObservedObject var model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.text("最近 7 天消耗", "Last 7 days"))
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(formattedTotal)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let points = snapshot.recent7DayUsage() {
                Chart(points) { point in
                    BarMark(
                        x: .value("Date", point.date, unit: .day),
                        y: .value("Tokens", point.tokens)
                    )
                    .foregroundStyle(snapshot.todayUsage()?.estimated == true && Calendar.current.isDateInToday(point.date) ? Color.orange : Color.blue)
                    .cornerRadius(2)
                }
                .chartLegend(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.secondary.opacity(0.25))
                        AxisValueLabel { Text(shortTokens(value.as(Int.self) ?? 0)) }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 1)) { value in
                        AxisTick()
                        AxisValueLabel(format: .dateTime.month(.twoDigits).day(.twoDigits))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 122)
                .accessibilityLabel(model.text("最近 7 天每日 Token 消耗图", "Daily token usage for the last 7 days"))
            } else {
                Text(model.text("暂无每日消耗数据", "Daily usage is unavailable"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .padding(.top, 2)
    }

    private var formattedTotal: String {
        guard let total = snapshot.recent30DayTotalIncludingToday() else { return "—" }
        return model.text("30 天合计 \(total.formatted())", "30d total \(total.formatted())")
    }

    private func shortTokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", Double(value) / 1_000) }
        return value.formatted()
    }
}

struct SettingsView: View {
    @ObservedObject var model: UsageModel
    var body: some View {
        ZStack {
            GlassSurface(cornerRadius: 0).ignoresSafeArea()
            Form {
                Section { Picker(model.text("语言", "Language"), selection: $model.language) { ForEach(AppLanguage.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented) }
                Section(model.text("状态栏展示", "Status bar display")) {
                    ForEach(model.providers, id: \.id) { provider in
                        Toggle(isOn: Binding(get: { model.selectedProviderIDs.contains(provider.id) }, set: { _ in model.toggle(provider.id) })) {
                            Label(provider.displayName, systemImage: provider.id == "codex" ? "sparkles" : "square.grid.2x2")
                        }
                    }
                    Text(model.text("可多选，后续可扩展更多 AI 应用。", "Select multiple apps; more providers can be added later.")).font(.caption).foregroundStyle(.secondary)
                }
                Section(model.text("刷新频率", "Refresh interval")) {
                    Picker(model.text("自动刷新", "Automatic refresh"), selection: $model.refreshInterval) {
                        ForEach(RefreshInterval.allCases) { interval in
                            Text(model.language == .chinese ? interval.chineseLabel : interval.englishLabel)
                                .tag(interval)
                        }
                    }
                }
                Section { Button(model.text("立即刷新", "Refresh now"), action: model.refresh).buttonStyle(.borderless) }.disabled(model.isRefreshing)
            }.formStyle(.grouped).scrollContentBackground(.hidden).frame(width: 540, height: 400)
        }
    }
}
