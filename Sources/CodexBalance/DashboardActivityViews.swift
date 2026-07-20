import CodexBalanceCore
import SwiftUI

struct DashboardAnalyticsSectionView: View {
    let snapshot: LocalUsageAnalyticsSnapshot
    let now: Date
    @Binding var rangeDays: Int
    @Environment(\.dashboardDisplayAccessibility) private var displayAccessibility

    var body: some View {
        let comparison = TodayVsNormalPresentation(snapshot: self.snapshot, now: self.now)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                DashboardSectionTitle("Local activity", systemImage: "chart.bar.xaxis")
                Spacer()
                Menu {
                    ForEach([7, 14, 30], id: \.self) { days in
                        Button {
                            self.rangeDays = days
                        } label: {
                            if self.rangeDays == days {
                                Label("\(days)d", systemImage: "checkmark")
                            } else {
                                Text("\(days)d")
                            }
                        }
                    }
                } label: {
                    Label("\(self.rangeDays)d", systemImage: "calendar")
                        .frame(minWidth: 42, minHeight: 28)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.large)
                .frame(minWidth: 62, minHeight: 28)
                .contentShape(Rectangle())
                .focusable(true)
                .accessibilityIdentifier("codexbalance.dashboard.activity-range")
            }
            if self.snapshot.hasAnyData {
                DashboardTodayVsNormalView(presentation: comparison)
                DashboardAnalyticsHistogram(
                    slots: self.histogramSlots,
                    baselineTokens: comparison.baselineTokens)
                    .frame(height: 92)
                Text("Estimated from local token metadata. Not official quota or billing.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardDesignTokens.secondaryText)
            } else {
                DashboardNotice(
                    message: LocalUsageAnalyticsFormatter.unavailableText(self.snapshot),
                    color: DashboardDesignTokens.secondaryText)
            }
        }
        .padding(12)
        .background(DashboardDesignTokens.contentSurface(self.displayAccessibility))
        .clipShape(RoundedRectangle(cornerRadius: DashboardDesignTokens.radius))
        .overlay {
            RoundedRectangle(cornerRadius: DashboardDesignTokens.radius)
                .stroke(DashboardDesignTokens.border(self.displayAccessibility), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Local activity from logs. Estimated token activity, not official quota or billing.")
        .accessibilityIdentifier("codexbalance.dashboard.analytics")
    }

    private var histogramSlots: [DashboardHistogramSlot] {
        let calendar = Calendar.current
        let byDate = Dictionary(uniqueKeysWithValues: self.snapshot.dailyHistory.map { ($0.date, $0) })
        return (0..<self.rangeDays).map { index in
            let offset = -(self.rangeDays - 1 - index)
            let date = calendar.date(byAdding: .day, value: offset, to: self.now) ?? self.now
            let key = LocalUsageLogScanner.dayFormatter.string(from: date)
            return DashboardHistogramSlot(
                date: key,
                displayDate: Self.shortDateFormatter.string(from: date),
                totalTokens: byDate[key]?.totalTokens,
                isToday: index == self.rangeDays - 1)
        }
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()
}

private struct DashboardTodayVsNormalView: View {
    let presentation: TodayVsNormalPresentation

    var body: some View {
        HStack(spacing: 16) {
            self.metric("Today", self.presentation.todayText)
            Divider().frame(height: 34)
            self.metric("Normal", self.presentation.normalText)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(self.presentation.deltaText)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(self.presentation.confidenceText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardDesignTokens.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Today \(self.presentation.todayText) tokens. Normal \(self.presentation.normalText). \(self.presentation.deltaText). \(self.presentation.confidenceText).")
        .accessibilityIdentifier("codexbalance.dashboard.today-vs-normal")
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(DashboardDesignTokens.secondaryText)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}

struct DashboardRecentWorkSectionView: View {
    let snapshot: LocalUsageAnalyticsSnapshot
    let now: Date
    @Environment(\.dashboardDisplayAccessibility) private var displayAccessibility

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DashboardSectionTitle("Recent work", systemImage: "clock.arrow.circlepath")
            if self.snapshot.recentWork.isEmpty {
                Text("Recent local work becomes available from read-only token metadata.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardDesignTokens.secondaryText)
            } else {
                ForEach(self.snapshot.recentWork.prefix(3)) { item in
                    HStack(spacing: 8) {
                        Text(DashboardPresentation.relativeAge(max(0, self.now.timeIntervalSince(item.observedAt))))
                            .foregroundStyle(DashboardDesignTokens.secondaryText)
                            .frame(width: 36, alignment: .leading)
                        Text(item.model).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(LocalUsageAnalyticsFormatter.tokenText(item.tokenActivity))
                            .monospacedDigit()
                        Text(item.confidence)
                            .foregroundStyle(DashboardDesignTokens.secondaryText)
                    }
                    .font(.system(size: 10.5))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent Codex work from local token metadata")
        .accessibilityIdentifier("codexbalance.dashboard.recent-work")
    }
}

struct DashboardMetricTile: View {
    let title: String
    let value: String
    @Environment(\.dashboardDisplayAccessibility) private var displayAccessibility

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.title)
                .font(.system(size: 10.5))
                .foregroundStyle(DashboardDesignTokens.secondaryText)
            Text(self.value)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 8)
        .background(DashboardDesignTokens.subtleSurface(self.displayAccessibility))
        .clipShape(RoundedRectangle(cornerRadius: DashboardDesignTokens.compactRadius))
    }
}

struct DashboardHistogramSlot: Identifiable {
    let date: String
    let displayDate: String
    let totalTokens: Int?
    let isToday: Bool

    var id: String { self.date }
}

struct DashboardAnalyticsHistogram: View {
    let slots: [DashboardHistogramSlot]
    let baselineTokens: Int?

    var body: some View {
        let maximum = max(1, self.slots.compactMap(\.totalTokens).max() ?? 1)
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                if let baselineTokens, baselineTokens > 0 {
                    GeometryReader { proxy in
                        let ratio = min(1, CGFloat(baselineTokens) / CGFloat(maximum))
                        Rectangle()
                            .fill(DashboardDesignTokens.secondaryText.opacity(0.62))
                            .frame(height: 1)
                            .offset(y: proxy.size.height * (1 - ratio))
                    }
                    Text("Normal")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(DashboardDesignTokens.secondaryText)
                        .padding(.horizontal, 3)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.78))
                }
                HStack(alignment: .bottom, spacing: 3) {
                ForEach(self.slots) { slot in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(self.barColor(slot))
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 2,
                            maxHeight: max(2, CGFloat(slot.totalTokens ?? 0) / CGFloat(maximum) * 68))
                        .accessibilityRepresentation {
                            Text(self.accessibilityText(for: slot))
                                .accessibilityIdentifier("codexbalance.dashboard.histogram.\(slot.date)")
                        }
                }
                }
            }
            HStack {
                Text(self.slots.first?.displayDate ?? "")
                Spacer()
                Text("Today")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(DashboardDesignTokens.secondaryText)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(self.slots.count) day local token histogram. Today is labeled and the normal guide appears when available.")
    }

    private func barColor(_ slot: DashboardHistogramSlot) -> Color {
        guard let totalTokens = slot.totalTokens, totalTokens > 0 else { return DashboardDesignTokens.track }
        return slot.isToday
            ? DashboardDesignTokens.brand
            : DashboardDesignTokens.brand.opacity(0.58)
    }

    private func accessibilityText(for slot: DashboardHistogramSlot) -> String {
        let date = slot.isToday ? "Today, \(slot.displayDate)" : slot.displayDate
        let value = slot.totalTokens.map { "\($0) estimated tokens" } ?? "No dated activity"
        return "\(date), \(value)"
    }
}
