import CodexBalanceCore
import SwiftUI

private struct DashboardKeyboardAction: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .focusable(true)
            .onKeyPress(.space) {
                self.action()
                return .handled
            }
            .onKeyPress(.return) {
                self.action()
                return .handled
            }
    }
}

private extension View {
    func dashboardKeyboardAction(_ action: @escaping () -> Void) -> some View {
        self.modifier(DashboardKeyboardAction(action: action))
    }
}

struct DashboardDetailsSectionView: View {
    let state: UsageDiagnosticsState
    let analytics: LocalUsageAnalyticsSnapshot
    @Binding var isExpanded: Bool
    @Binding var copied: Bool
    let onCopy: () -> Void
    @Environment(\.dashboardDisplayAccessibility) private var displayAccessibility

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                self.isExpanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Details")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: self.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dashboardKeyboardAction { self.isExpanded.toggle() }
            .accessibilityLabel(self.isExpanded ? "Collapse Details" : "Expand Details")
            .accessibilityIdentifier("codexbalance.dashboard.details-toggle")

            if self.isExpanded {
            VStack(alignment: .leading, spacing: 7) {
                DashboardSectionTitle("Activity telemetry", systemImage: "chart.xyaxis.line")
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                    spacing: 8)
                {
                    DashboardMetricTile("Today cost", LocalUsageAnalyticsFormatter.costText(self.analytics.todayCostUSD))
                    DashboardMetricTile("30d cost", LocalUsageAnalyticsFormatter.costText(self.analytics.last30DaysCostUSD))
                    DashboardMetricTile("Today tokens", LocalUsageAnalyticsFormatter.tokenText(self.analytics.todayTokens))
                    DashboardMetricTile("30d tokens", LocalUsageAnalyticsFormatter.tokenText(self.analytics.last30DaysTokens))
                    DashboardMetricTile("Latest tokens", LocalUsageAnalyticsFormatter.tokenText(self.analytics.latestTokens))
                    DashboardMetricTile("Top model", self.analytics.topModel ?? "unavailable")
                }
                Text(LocalUsageAnalyticsFormatter.estimateShortNote(self.analytics))
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardDesignTokens.secondaryText)
                Divider().overlay(DashboardDesignTokens.divider(self.displayAccessibility))
                DashboardDiagnosticRow("Last success", Self.dateText(self.state.lastSuccessfulRefreshAt))
                DashboardDiagnosticRow("Last error", self.state.lastErrorCategory)
                DashboardDiagnosticRow("Next refresh", self.state.nextRefreshSummary)
                DashboardDiagnosticRow("Refresh mode", self.state.refreshMode)
                DashboardDiagnosticRow("Source order", "OAuth, CLI RPC, local fallback")
                DashboardDiagnosticRow("Local analytics", self.state.analyticsStatus)
                Button {
                    self.onCopy()
                } label: {
                    Label(
                        self.copied ? "Copied" : "Copy sanitized diagnostics",
                        systemImage: self.copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(minHeight: 28)
                .dashboardKeyboardAction(self.onCopy)
                .accessibilityIdentifier("codexbalance.dashboard.copy-diagnostics")
            }
            .padding(.top, 8)
            }
        }
        .padding(12)
        .background(DashboardDesignTokens.subtleSurface(self.displayAccessibility))
        .clipShape(RoundedRectangle(cornerRadius: DashboardDesignTokens.radius))
        .overlay {
            RoundedRectangle(cornerRadius: DashboardDesignTokens.radius)
                .stroke(DashboardDesignTokens.border(self.displayAccessibility), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details. Activity telemetry and sanitized diagnostics.")
        .accessibilityIdentifier("codexbalance.dashboard.diagnostics")
    }

    private static func dateText(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return ISO8601DateFormatter().string(from: date)
    }
}

struct DashboardDiagnosticRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(self.title).foregroundStyle(DashboardDesignTokens.secondaryText)
            Spacer(minLength: 12)
            Text(self.value)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 10.5))
    }
}

struct DashboardFooterView: View {
    let isRefreshing: Bool
    let isPinned: Bool
    let mode: RefreshMode
    let footerStatus: String
    let refreshFeedback: String?
    let onRefresh: () -> Void
    let onPin: () -> Void
    let onSetMode: (RefreshMode) -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: self.onRefresh) {
                    HStack(spacing: 5) {
                        if self.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Refresh")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(width: 74, height: 28)
                }
                .disabled(self.isRefreshing)
                .dashboardKeyboardAction(self.onRefresh)
                .help("Refresh quota and local activity")
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityLabel(self.refreshFeedback ?? (self.isRefreshing ? "Refreshing" : "Refresh"))
                .accessibilityIdentifier("codexbalance.dashboard.refresh")

                Button(action: self.onPin) {
                    Label(
                        self.isPinned ? "Unpin" : "Pin",
                        systemImage: self.isPinned ? "pin.slash" : "pin")
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: 64, height: 28)
                }
                .keyboardShortcut("p", modifiers: .command)
                .dashboardKeyboardAction(self.onPin)
                .help(self.isPinned ? "Allow the dashboard to dismiss" : "Keep the dashboard open")
                .accessibilityIdentifier("codexbalance.dashboard.pin")

                Menu {
                    ForEach(RefreshMode.allCases) { mode in
                        Button {
                            self.onSetMode(mode)
                        } label: {
                            if self.mode == mode {
                                Label(mode.label, systemImage: "checkmark")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                } label: {
                    Label(self.mode.label, systemImage: "timer")
                        .frame(width: 64, height: 28)
                }
                .controlSize(.large)
                .frame(height: 28)
                .contentShape(Rectangle())
                .focusable(true)
                .help("Choose Smart Refresh mode")
                .accessibilityLabel("Smart Refresh, \(self.mode.label)")
                .accessibilityIdentifier("codexbalance.dashboard.cadence")

                Spacer()
                Button(action: self.onQuit) {
                    Image(systemName: "power")
                        .frame(width: 24, height: 28)
                }
                .help("Quit CodexBalance")
                .dashboardKeyboardAction(self.onQuit)
                .accessibilityLabel("Quit CodexBalance")
                .accessibilityIdentifier("codexbalance.dashboard.quit")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            Text("Smart Refresh · \(self.mode.label) · \(self.footerStatus)")
                .font(.system(size: 10.5))
                .foregroundStyle(DashboardDesignTokens.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 62)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Smart Refresh controls. \(self.footerStatus)")
        .accessibilityIdentifier("codexbalance.dashboard.footer")
    }
}
