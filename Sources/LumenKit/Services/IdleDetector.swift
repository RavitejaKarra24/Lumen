import CoreGraphics
import Foundation

struct IdleDetector: Sendable {
    /// Seconds of keyboard/mouse inactivity after which we mark the user idle.
    var threshold: TimeInterval

    init(threshold: TimeInterval = 120) {
        self.threshold = threshold
    }

    /// Uses HID idle time — no special permission required.
    func secondsIdle() -> TimeInterval {
        // ~0 as CGEventType means "any event"
        let any: CGEventType = CGEventType(rawValue: UInt32.max)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    func isIdle(now: Date = .now) -> Bool {
        secondsIdle() >= threshold
    }
}
