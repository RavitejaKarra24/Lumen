import ApplicationServices
import AppKit
import Foundation

@MainActor
@Observable
final class PermissionManager {
    var hasAccessibility: Bool = AXIsProcessTrusted()
    var lastCheckedAt: Date = .now

    func refresh() {
        hasAccessibility = AXIsProcessTrusted()
        lastCheckedAt = .now
    }

    /// Opens the system prompt / Settings pane for Accessibility access.
    func requestAccessibility() {
        // String key avoids Swift 6 shared-mutable-state diagnostic on the CF constant.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        hasAccessibility = AXIsProcessTrustedWithOptions(options)
        lastCheckedAt = .now

        // Also open Settings in case the prompt is suppressed.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
