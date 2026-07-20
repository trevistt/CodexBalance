import AppKit
import SwiftUI

struct DashboardDisplayAccessibility: Equatable {
    var reduceTransparency: Bool
    var increaseContrast: Bool
    var reduceMotion: Bool
    var useWithinWindowBlending: Bool

    static var system: DashboardDisplayAccessibility {
        DashboardDisplayAccessibility(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            useWithinWindowBlending: false)
    }

    static let standardFixture = DashboardDisplayAccessibility(
        reduceTransparency: false,
        increaseContrast: false,
        reduceMotion: false,
        useWithinWindowBlending: true)
}

private struct DashboardDisplayAccessibilityKey: EnvironmentKey {
    static let defaultValue = DashboardDisplayAccessibility.system
}

extension EnvironmentValues {
    var dashboardDisplayAccessibility: DashboardDisplayAccessibility {
        get { self[DashboardDisplayAccessibilityKey.self] }
        set { self[DashboardDisplayAccessibilityKey.self] = newValue }
    }
}

struct DashboardMaterialSurface<Content: View>: View {
    let accessibility: DashboardDisplayAccessibility
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            DashboardVisualEffectView(configuration: self.accessibility)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            if self.accessibility.reduceTransparency {
                Color(nsColor: .windowBackgroundColor).opacity(0.96)
            } else {
                Color(nsColor: .windowBackgroundColor).opacity(0.08)
            }
            self.content()
        }
        .environment(\.dashboardDisplayAccessibility, self.accessibility)
    }
}

private struct DashboardVisualEffectView: NSViewRepresentable {
    let configuration: DashboardDisplayAccessibility

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.wantsLayer = true
        view.setAccessibilityElement(false)
        self.configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        self.configure(view)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = .popover
        view.state = .followsWindowActiveState
        view.isEmphasized = self.configuration.increaseContrast
        view.alphaValue = self.configuration.reduceTransparency
            ? 1
            : (self.configuration.increaseContrast ? 0.98 : 0.94)
        if self.configuration.useWithinWindowBlending {
            view.blendingMode = .withinWindow
        } else {
            view.blendingMode = .behindWindow
        }
    }
}
