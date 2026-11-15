import AppKit
import ApplicationServices
import Foundation

/// Mutes the user's Zoom microphone while the dictation key is held by pressing
/// Zoom's own "Mute audio" menu item through Accessibility, then presses
/// "Unmute audio" on release — but only if this service did the muting.
///
/// Zoom's menu title lags slightly behind the real state, so every step reads the
/// current title, retries briefly, and only clears ownership after the title flips.
@MainActor
final class ZoomMuteService {
    static let shared = ZoomMuteService()

    private var weMuted = false
    private var chain: Task<Void, Never>?

    func recordingStarted(enabled: Bool) {
        guard enabled else { return }
        self.enqueue { [weak self] in
            guard let self, !(await self.weMuted) else { return }
            if await Self.mute() {
                await MainActor.run { self.weMuted = true }
            }
        }
    }

    func recordingStopped() {
        self.enqueue { [weak self] in
            guard let self, await self.weMuted else { return }
            if await Self.unmute() {
                await MainActor.run { self.weMuted = false }
            }
        }
    }

    /// Serialize start/stop so a quick tap can't unmute before the mute finished.
    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = self.chain
        self.chain = Task.detached {
            await previous?.value
            await work()
        }
    }

    // MARK: - Mute state machine

    nonisolated private static let muteTitle = "mute audio"
    nonisolated private static let unmuteTitle = "unmute audio"

    /// Waits for Zoom's menu title to catch up; it lags the real state by up to ~1s.
    nonisolated private static func waitForTitle(_ wanted: String, seconds: Double) async -> Bool {
        for _ in 0..<Int(seconds * 10) {
            if currentItem().1 == wanted { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// True only when this call muted Zoom (so the caller owns the unmute).
    nonisolated private static func mute() async -> Bool {
        for _ in 0..<10 {
            switch currentItem() {
            case let (item?, title?) where title == muteTitle:
                guard press(item) else { break }
                // Confirm before returning so the release never reads a stale title.
                let confirmed = await waitForTitle(unmuteTitle, seconds: 3)
                log(confirmed ? "muted" : "muted (title unconfirmed)")
                return true
            case (_?, let title?) where title == unmuteTitle:
                log("already muted by user; leaving as is")
                return false
            default:
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        log("mute skipped: Zoom mute item not found (not in a meeting?)")
        return false
    }

    /// True once Zoom reports unmuted again (or the user already unmuted).
    /// The menu item is a toggle, so press once and wait; pressing again while the
    /// title is stale would re-mute.
    nonisolated private static func unmute() async -> Bool {
        for attempt in 1...2 {
            guard case let (item?, title?) = currentItem() else {
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }
            if title == muteTitle {
                log(attempt == 1 ? "already unmuted by user" : "unmuted")
                return true
            }
            guard press(item) else { continue }
            if await waitForTitle(muteTitle, seconds: 3) {
                log("unmuted")
                return true
            }
        }
        log("unmute FAILED; will retry on next release")
        return false
    }

    nonisolated private static func log(_ message: String) {
        DebugLogger.shared.info("ZOOM_MUTE \(message)", source: "ZoomMuteService")
    }

    // MARK: - Accessibility

    /// The Meeting menu's mute toggle and its lowercased title, if Zoom is in a meeting.
    nonisolated private static func currentItem() -> (AXUIElement?, String?) {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "us.zoom.xos").first
        else { return (nil, nil) }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = attribute(root, kAXMenuBarAttribute) else { return (nil, nil) }
        // swiftlint:disable:next force_cast
        for top in children(menuBar as! AXUIElement) {
            for menu in children(top) {
                for item in children(menu) {
                    guard let title = (attribute(item, kAXTitleAttribute) as? String)?.lowercased() else { continue }
                    if title == muteTitle || title == unmuteTitle { return (item, title) }
                }
            }
        }
        return (nil, nil)
    }

    nonisolated private static func press(_ item: AXUIElement) -> Bool {
        AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    nonisolated private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    nonisolated private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}
