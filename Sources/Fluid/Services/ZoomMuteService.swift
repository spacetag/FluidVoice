import AppKit
import ApplicationServices
import Foundation

/// Mutes the user's Zoom microphone while the dictation key is held by pressing
/// Zoom's own "Mute Audio" menu item through Accessibility, then presses
/// "Unmute Audio" on release — but only if this service did the muting.
@MainActor
final class ZoomMuteService {
    static let shared = ZoomMuteService()

    private var weMuted = false
    private var chain: Task<Void, Never>?

    func recordingStarted(enabled: Bool) {
        guard enabled else { return }
        self.enqueue { [weak self] in
            guard let self, !(await self.weMuted) else { return }
            if Self.press(title: "Mute Audio") {
                await MainActor.run { self.weMuted = true }
                DebugLogger.shared.info("ZOOM_MUTE muted", source: "ZoomMuteService")
            }
        }
    }

    func recordingStopped() {
        self.enqueue { [weak self] in
            guard let self, await self.weMuted else { return }
            await MainActor.run { self.weMuted = false }
            _ = Self.press(title: "Unmute Audio")
            DebugLogger.shared.info("ZOOM_MUTE unmuted", source: "ZoomMuteService")
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

    // MARK: - Accessibility

    nonisolated private static func press(title: String) -> Bool {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "us.zoom.xos").first
        else { return false }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = attribute(root, kAXMenuBarAttribute) as! AXUIElement? else { return false }
        for top in children(menuBar) {
            for menu in children(top) {
                for item in children(menu) {
                    if attribute(item, kAXTitleAttribute) as? String == title {
                        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                    }
                }
            }
        }
        return false
    }

    nonisolated private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    nonisolated private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}
