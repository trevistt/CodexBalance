import CodexBalanceCore
import SwiftUI

struct DashboardRunwayPresentation: Equatable {
    let windowLabel: String
    let remainingText: String
    let resetText: String
    let decisionText: String
    let balanceText: String?
    let projectionText: String
    let projectionRelationText: String?
    let projectedEmptyAt: Date?
    let resetAt: Date?
    let isStale: Bool

    init?(row: DashboardQuotaRowPresentation, isStale: Bool, now: Date) {
        guard let remaining = row.row.remainingPercent else { return nil }
        self.windowLabel = row.row.label
        self.remainingText = "\(Int(remaining.rounded()))%"
        self.resetAt = row.row.resetAt
        self.resetText = row.row.resetAt.map {
            "Resets in \(UsageSnapshot.countdown(to: $0, now: now))"
        } ?? "Reset time unavailable"
        self.decisionText = row.pace.map(UsagePaceFormatter.decisionText) ?? "Pace target unavailable"
        self.balanceText = row.pace.map(UsagePaceFormatter.balanceText)
        self.projectionText = row.pace.map { UsagePaceFormatter.projectionText($0, now: now) }
            ?? "Projection unavailable"
        self.projectedEmptyAt = row.pace?.projectedEmptyAt
        if let emptyAt = row.pace?.projectedEmptyAt, let resetAt = row.row.resetAt {
            self.projectionRelationText = emptyAt < resetAt
                ? "\(UsageSnapshot.countdown(to: resetAt, now: emptyAt)) before reset"
                : "Expected to last through reset"
        } else {
            self.projectionRelationText = nil
        }
        self.isStale = isStale
    }
}

struct DashboardRunwayHeroView: View {
    let presentation: DashboardPresentation
    let now: Date
    @Environment(\.dashboardDisplayAccessibility) private var displayAccessibility

    var body: some View {
        Group {
            if let runway = self.presentation.runway {
                self.runway(runway)
            } else {
                self.unavailable
            }
        }
        .padding(14)
        .background(DashboardDesignTokens.runwaySurface(self.displayAccessibility))
        .clipShape(RoundedRectangle(cornerRadius: DashboardDesignTokens.radius))
        .overlay {
            RoundedRectangle(cornerRadius: DashboardDesignTokens.radius)
                .stroke(DashboardDesignTokens.border(self.displayAccessibility), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("codexbalance.dashboard.runway")
    }

    private func runway(_ runway: DashboardRunwayPresentation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(runway.remainingText)
                    .font(.system(size: 35, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .accessibilityLabel("\(runway.windowLabel) \(runway.remainingText) remaining")
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(runway.windowLabel) remaining")
                        .font(.system(size: 12, weight: .semibold))
                    Text(runway.resetText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(DashboardDesignTokens.secondaryText)
                }
                Spacer(minLength: 0)
                Text(runway.isStale ? "CACHED" : "LIVE")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(runway.isStale ? DashboardDesignTokens.cachedText : DashboardDesignTokens.safeText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background((runway.isStale ? DashboardDesignTokens.cached : DashboardDesignTokens.safe).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            HStack(alignment: .firstTextBaseline) {
                Text(runway.decisionText)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if let balance = runway.balanceText {
                    Text(balance)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(DashboardDesignTokens.secondaryText)
                }
            }
            DashboardRunwayTrack(runway: runway, now: self.now)
            if self.presentation.snapshot.isStale {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: self.presentation.statusSlot.symbol)
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(self.presentation.statusSlot.title). \(self.presentation.statusSlot.detail)")
                        .font(.system(size: 10.5, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(self.statusColor)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(self.presentation.statusSlot.title). \(self.presentation.statusSlot.detail)")
                .accessibilityIdentifier("codexbalance.dashboard.runway-status")
            }
        }
    }

    private var unavailable: some View {
        HStack(spacing: 12) {
            Image(systemName: self.presentation.statusSlot.symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(self.statusColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(self.presentation.statusSlot.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(self.presentation.statusSlot.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardDesignTokens.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 64)
    }

    private var statusColor: Color {
        switch self.presentation.statusSlot.tone {
        case .neutral: DashboardDesignTokens.brand
        case .safe: DashboardDesignTokens.safeText
        case .caution, .cached: DashboardDesignTokens.cautionText
        case .error: DashboardDesignTokens.errorText
        }
    }
}

private struct DashboardRunwayTrack: View {
    let runway: DashboardRunwayPresentation
    let now: Date
    @Environment(\.dashboardDisplayAccessibility) private var displayAccessibility

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DashboardDesignTokens.track)
                    if self.runway.resetAt != nil {
                        Capsule()
                            .fill(self.trackColor)
                            .frame(width: max(2, proxy.size.width * self.progressFraction))
                        Circle()
                            .fill(DashboardDesignTokens.primaryText)
                            .frame(width: 7, height: 7)
                            .offset(x: max(0, proxy.size.width * self.progressFraction - 3.5))
                    }
                }
            }
            .frame(height: self.displayAccessibility.increaseContrast ? 7 : 6)
            HStack(alignment: .top) {
                Text("Now")
                Spacer()
                VStack(spacing: 1) {
                    Text(self.runway.projectionText)
                        .fontWeight(.semibold)
                    if let relation = self.runway.projectionRelationText {
                        Text(relation)
                    }
                }
                .multilineTextAlignment(.center)
                Spacer()
                Text(self.runway.resetAt == nil ? "Reset unavailable" : "Reset")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(DashboardDesignTokens.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Runway. Now. \(self.runway.projectionText). \(self.runway.projectionRelationText ?? ""). \(self.runway.resetText).")
    }

    private var progressFraction: CGFloat {
        guard let reset = self.runway.resetAt,
              let empty = self.runway.projectedEmptyAt,
              reset > self.now
        else { return 1 }
        let remaining = reset.timeIntervalSince(self.now)
        let toEmpty = max(0, empty.timeIntervalSince(self.now))
        return CGFloat(min(1, toEmpty / remaining))
    }

    private var trackColor: Color {
        if self.runway.isStale { return DashboardDesignTokens.cached }
        if let reset = self.runway.resetAt,
           let empty = self.runway.projectedEmptyAt,
           empty < reset
        {
            return DashboardDesignTokens.caution
        }
        return DashboardDesignTokens.brand
    }
}
