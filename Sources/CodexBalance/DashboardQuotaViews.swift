import CodexBalanceCore
import SwiftUI

struct DashboardHeaderView: View {
    let presentation: DashboardPresentation

    var body: some View {
        HStack(spacing: 9) {
            AppBrandIconView(size: 20)
                .foregroundStyle(DashboardDesignTokens.primaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex")
                    .font(.system(size: 15, weight: .semibold))
                Text(self.presentation.headerStatus)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardDesignTokens.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DashboardDesignTokens.horizontalInset)
        .frame(height: 52)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex. \(self.presentation.headerStatus)")
        .accessibilityIdentifier("codexbalance.dashboard.header")
    }
}

struct DashboardQuotaSectionView: View {
    let presentation: DashboardPresentation
    let now: Date
    @Environment(\.dashboardDisplayAccessibility) private var displayAccessibility

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            DashboardSectionTitle("Quota windows", systemImage: "gauge.with.dots.needle.67percent")
            VStack(spacing: 0) {
                ForEach(Array(self.presentation.quotaRows.enumerated()), id: \.element.id) { index, row in
                    DashboardQuotaRow(row: row, isStale: self.presentation.snapshot.isStale, now: self.now)
                    if index < self.presentation.quotaRows.count - 1 {
                        Divider().overlay(DashboardDesignTokens.divider(self.displayAccessibility))
                    }
                }
            }
            if !self.presentation.snapshot.extraWindows.isEmpty {
                DashboardExtraWindows(windows: self.presentation.snapshot.extraWindows, now: self.now)
            }
        }
        .accessibilityIdentifier("codexbalance.dashboard.quota")
    }
}

private struct DashboardQuotaRow: View {
    let row: DashboardQuotaRowPresentation
    let isStale: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(self.row.row.label)
                    .font(.system(size: 12, weight: .semibold))
                if self.row.isLimiting {
                    Text("LIMITING")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(DashboardDesignTokens.cautionText)
                }
                Spacer()
                Text(self.row.row.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "--")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            DashboardQuotaProgressBar(
                remainingPercent: self.row.row.remainingPercent,
                targetRemainingPercent: self.row.pace?.targetRemainingPercent,
                isStale: self.isStale)
                .frame(height: 6)
            HStack(spacing: 8) {
                Text(self.row.row.resetAt.map { "Resets in \(UsageSnapshot.countdown(to: $0, now: self.now))" }
                    ?? "Reset time unavailable")
                Spacer(minLength: 0)
                if let pace = self.row.pace {
                    Text(UsagePaceFormatter.balanceText(pace))
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(DashboardDesignTokens.secondaryText)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.accessibilitySummary)
        .accessibilityIdentifier("codexbalance.dashboard.quota.\(self.row.row.role.rawValue)")
    }

    private var accessibilitySummary: String {
        let remaining = self.row.row.remainingPercent.map { "\(Int($0.rounded())) percent remaining" }
            ?? "remaining quota unavailable"
        let projection = self.row.pace.map { UsagePaceFormatter.projectionText($0, now: self.now) }
            ?? "pace target unavailable"
        let limiting = self.row.isLimiting ? ". This is the limiting quota window" : ""
        return "\(self.row.row.label). \(remaining). \(projection)\(limiting)"
    }
}

private struct DashboardExtraWindows: View {
    let windows: [UsageNamedWindow]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Additional windows")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DashboardDesignTokens.secondaryText)
            ForEach(self.windows) { item in
                HStack {
                    Text(item.title).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(Int(item.window.remainingPercent.rounded()))%")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                    Text(item.window.resetAt.map { UsageSnapshot.countdown(to: $0, now: self.now) } ?? "--")
                        .foregroundStyle(DashboardDesignTokens.secondaryText)
                        .frame(width: 45, alignment: .trailing)
                }
                .font(.system(size: 10.5))
            }
        }
        .padding(.top, 4)
        .accessibilityIdentifier("codexbalance.dashboard.extra-windows")
    }
}

struct DashboardObservationSectionView: View {
    let presentation: DashboardPresentation
    let lastQuotaChangedAt: Date?
    let now: Date
    @Environment(\.dashboardDisplayAccessibility) private var displayAccessibility

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DashboardSectionTitle("Latest check", systemImage: "checkmark.circle")
            HStack(alignment: .firstTextBaseline) {
                Text(self.presentation.observationText)
                    .font(.system(size: 11.5, weight: .medium))
                Spacer(minLength: 8)
                if let changedAt = self.lastQuotaChangedAt {
                    Text("Changed \(DashboardPresentation.relativeAge(max(0, self.now.timeIntervalSince(changedAt)))) ago")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DashboardDesignTokens.secondaryText)
                }
            }
            Text(self.detail)
                .font(.system(size: 10.5))
                .foregroundStyle(DashboardDesignTokens.secondaryText)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Latest check. \(self.presentation.observationText). \(self.detail)")
        .accessibilityIdentifier("codexbalance.dashboard.observation")
    }

    private var detail: String {
        if let changedAt = self.lastQuotaChangedAt {
            return "Last observed quota change \(DashboardPresentation.relativeAge(max(0, self.now.timeIntervalSince(changedAt)))) ago."
        }
        return self.presentation.observationDetail
    }
}

struct DashboardSectionTitle: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label(self.title, systemImage: self.systemImage)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(DashboardDesignTokens.secondaryText)
    }
}

struct DashboardNotice: View {
    let message: String
    let color: Color

    var body: some View {
        Text(self.message)
            .font(.system(size: 10.5))
            .foregroundStyle(self.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(self.color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: DashboardDesignTokens.compactRadius))
    }
}

struct DashboardQuotaProgressBar: View {
    let remainingPercent: Double?
    let targetRemainingPercent: Double?
    let isStale: Bool
    @Environment(\.dashboardDisplayAccessibility) private var displayAccessibility

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DashboardDesignTokens.track)
                Capsule()
                    .fill(self.isStale ? DashboardDesignTokens.cached : DashboardDesignTokens.brand)
                    .frame(width: proxy.size.width * self.remainingFraction)
                if let targetRemainingPercent {
                    Rectangle()
                        .fill(DashboardDesignTokens.primaryText)
                        .frame(width: self.displayAccessibility.increaseContrast ? 2.5 : 1.5, height: proxy.size.height + 4)
                        .offset(x: proxy.size.width * CGFloat(targetRemainingPercent / 100))
                }
            }
        }
        .accessibilityLabel("Remaining quota")
        .accessibilityValue(self.remainingPercent.map { "\(Int($0.rounded())) percent" } ?? "Unavailable")
        .accessibilityHint(self.targetRemainingPercent == nil
            ? "No pace target is available for this quota window."
            : "The marker shows the remaining quota target for the current pace.")
    }

    private var remainingFraction: CGFloat {
        CGFloat(min(100, max(0, self.remainingPercent ?? 0)) / 100)
    }
}
