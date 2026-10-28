import AppKit
import ApplicationServices
import Foundation

/// Reads the frontmost window title and, for browsers, the active URL via Accessibility.
struct BrowserInspector: Sendable {
    private let mozillaSessionReader = MozillaSessionReader()

    struct Snapshot: Sendable, Equatable {
        var appName: String
        var bundleIdentifier: String
        var windowTitle: String
        var urlString: String?
        var pid: pid_t
    }

    func captureFrontmost() -> Snapshot? {
        guard AXIsProcessTrusted() else {
            return captureWithoutAccessibility()
        }

        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let appName = app.localizedName ?? "Unknown"
        let bundleID = app.bundleIdentifier ?? "unknown"

        let axApp = AXUIElementCreateApplication(pid)
        let windowTitle = focusedWindowTitle(axApp: axApp)
            ?? firstWindowTitle(axApp: axApp)
            ?? appName

        var urlString: String?
        if CategoryClassifier.isBrowser(bundleIdentifier: bundleID) {
            // Firefox-family browser chrome is inconsistently exposed through AX.
            // Prefer its session data so a tab switch cannot pair a stale title
            // with a newly focused address bar URL.
            urlString = mozillaSessionReader.activeURL(
                bundleIdentifier: bundleID,
                windowTitle: windowTitle
            ) ?? extractBrowserURL(axApp: axApp, bundleID: bundleID, windowTitle: windowTitle)
        }

        return Snapshot(
            appName: appName,
            bundleIdentifier: bundleID,
            windowTitle: windowTitle,
            urlString: urlString,
            pid: pid
        )
    }

    // MARK: - Private

    private func captureWithoutAccessibility() -> Snapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return Snapshot(
            appName: app.localizedName ?? "Unknown",
            bundleIdentifier: app.bundleIdentifier ?? "unknown",
            windowTitle: "",
            urlString: nil,
            pid: app.processIdentifier
        )
    }

    private func focusedWindowTitle(axApp: AXUIElement) -> String? {
        guard let window = copyElement(axApp, kAXFocusedWindowAttribute as String) else { return nil }
        return copyString(window, kAXTitleAttribute as String)
    }

    private func firstWindowTitle(axApp: AXUIElement) -> String? {
        guard let windows = copyElements(axApp, kAXWindowsAttribute as String),
              let first = windows.first
        else { return nil }
        return copyString(first, kAXTitleAttribute as String)
    }

    private func extractBrowserURL(axApp: AXUIElement, bundleID: String, windowTitle: String) -> String? {
        if let window = copyElement(axApp, kAXFocusedWindowAttribute as String) {
            if let doc = copyString(window, kAXDocumentAttribute as String), looksLikeURL(doc) {
                return normalizeURL(doc)
            }
            if let url = findAddressBarURL(in: window, bundleID: bundleID) {
                return url
            }
        }

        if let windows = copyElements(axApp, kAXWindowsAttribute as String) {
            for window in windows.prefix(4) {
                if let doc = copyString(window, kAXDocumentAttribute as String), looksLikeURL(doc) {
                    return normalizeURL(doc)
                }
                if let url = findAddressBarURL(in: window, bundleID: bundleID) {
                    return url
                }
            }
        }

        if let inferred = inferURLFromTitle(windowTitle) {
            return inferred
        }

        return nil
    }

    private func findAddressBarURL(in root: AXUIElement, bundleID: String) -> String? {
        let keywords = addressBarKeywords(for: bundleID)
        var stack: [AXUIElement] = [root]
        var visited = 0
        let limit = 250

        while let current = stack.popLast(), visited < limit {
            visited += 1

            let role = copyString(current, kAXRoleAttribute as String) ?? ""
            let subrole = copyString(current, kAXSubroleAttribute as String) ?? ""
            let title = copyString(current, kAXTitleAttribute as String) ?? ""
            let description = copyString(current, kAXDescriptionAttribute as String) ?? ""
            let identifier = copyString(current, "AXIdentifier") ?? ""

            let haystack = [title, description, identifier, subrole].joined(separator: " ").lowercased()
            let isTextish = role == (kAXTextFieldRole as String)
                || role == (kAXComboBoxRole as String)
                || subrole.lowercased().contains("search")
                || role.lowercased().contains("text")

            if isTextish {
                let matched = keywords.contains { haystack.contains($0) }
                    || haystack.contains("address")
                    || haystack.contains("url")
                    || haystack.contains("location")
                if matched || keywords.isEmpty {
                    if let value = copyString(current, kAXValueAttribute as String),
                       looksLikeURL(value) {
                        return normalizeURL(value)
                    }
                }
            }

            if let urlValue = copyString(current, "AXURL"), looksLikeURL(urlValue) {
                return normalizeURL(urlValue)
            }

            if let children = copyElements(current, kAXChildrenAttribute as String) {
                stack.append(contentsOf: children.reversed())
            }
        }
        return nil
    }

    private func addressBarKeywords(for bundleID: String) -> [String] {
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return ["address", "search", "url", "location"]
        case "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser",
             "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera":
            return ["address", "search", "omnibox", "url"]
        case "company.thebrowser.Browser", "company.thebrowser.dia":
            return ["address", "search", "url", "command"]
        case "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition":
            return ["search", "address", "url"]
        case "app.zen-browser.zen":
            return ["search", "address", "url", "location"]
        default:
            return ["address", "url", "search", "location"]
        }
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard result == .success, let ref else { return nil }
        // AXUIElement is a CFType; bridge carefully.
        let typeID = CFGetTypeID(ref)
        guard typeID == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private func copyElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard result == .success, let ref else { return nil }
        return ref as? [AXUIElement]
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard result == .success, let ref else { return nil }

        if let string = ref as? String {
            return string
        }
        if let attributedString = ref as? NSAttributedString {
            return attributedString.string
        }
        if CFGetTypeID(ref) == CFURLGetTypeID() {
            let cfURL = unsafeDowncast(ref as AnyObject, to: NSURL.self)
            return cfURL.absoluteString
        }
        return nil
    }

    private func looksLikeURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("file://") {
            return true
        }
        if trimmed.contains(" "), !trimmed.contains("/") { return false }
        if trimmed.contains(".") && !trimmed.contains(" ") {
            let host = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
            return host.contains(".")
        }
        return false
    }

    private func normalizeURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("file://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    private func inferURLFromTitle(_ title: String) -> String? {
        let cleaned = title
            .replacingOccurrences(of: " - Google Chrome", with: "")
            .replacingOccurrences(of: " — Mozilla Firefox", with: "")
            .replacingOccurrences(of: " - Brave", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeURL(cleaned), !cleaned.contains(" ") {
            return normalizeURL(cleaned)
        }
        return nil
    }
}
