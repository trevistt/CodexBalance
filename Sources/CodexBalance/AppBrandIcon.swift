import AppKit
import SwiftUI

@MainActor
enum AppBrandIcon {
    private static var cachedImage: NSImage?

    private static var resourceBundle: Bundle? {
        let name = "CodexBalance_CodexBalance.bundle"
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(name))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(name))
        if let executableURL = Bundle.main.executableURL {
            candidates.append(executableURL.deletingLastPathComponent().appendingPathComponent(name))
        }
        return candidates.lazy.compactMap(Bundle.init(url:)).first
    }

    private static var resourceURL: URL? {
        guard let bundle = self.resourceBundle else { return nil }
        return bundle.url(forResource: "codex-balance-mark", withExtension: "svg")
            ?? bundle.url(
                forResource: "codex-balance-mark",
                withExtension: "svg",
                subdirectory: "BrandIcons")
    }

    static func image(size: CGFloat = 12, template: Bool = true) -> NSImage? {
        if let cachedImage {
            let copy = cachedImage.copy() as? NSImage
            copy?.size = NSSize(width: size, height: size)
            copy?.isTemplate = template
            return copy
        }
        guard let url = self.resourceURL,
              let loaded = NSImage(contentsOf: url)
        else {
            return nil
        }
        loaded.isTemplate = true
        self.cachedImage = loaded
        let copy = loaded.copy() as? NSImage
        copy?.size = NSSize(width: size, height: size)
        copy?.isTemplate = template
        return copy
    }

    static var isAvailable: Bool {
        self.resourceURL != nil && self.image() != nil
    }
}

struct AppBrandIconView: View {
    let size: CGFloat

    init(size: CGFloat = 16) {
        self.size = size
    }

    var body: some View {
        if let image = AppBrandIcon.image(size: self.size) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: self.size, height: self.size)
        } else {
            Text("CB")
                .font(.system(size: max(8, self.size * 0.68), weight: .bold))
        }
    }
}
