//
//  HiddenMenuBarItem.swift
//  boringNotch
//
//  Created for The Notch Bar: Phase 1 - Hidden Menu Bar Icon Detection
//

import AppKit

struct HiddenMenuBarItem: Identifiable, Hashable {
    /// Unique key for dedup and identity.
    /// Format: "\(pid):\(bundleID ?? "unknown"):\(axIdentifier ?? title ?? "\(Int(frame.origin.x))")"
    let id: String

    /// The PID of the owning application
    let pid: pid_t

    /// Bundle identifier of the owning app (nil for system agents)
    let bundleIdentifier: String?

    /// The app's localised name
    let appName: String

    /// AXIdentifier from the menu bar item (may be nil)
    let axIdentifier: String?

    /// AXTitle from the menu bar item (may be nil)
    let title: String?

    /// The AXFrame of the item in screen coordinates (logical points, not pixels)
    let frame: CGRect

    /// The live AXUIElement reference for performing actions
    let element: AXUIElement

    /// Snapshot of the icon image, captured via AX or CGWindow, for display in the row.
    /// Nil if capture failed; UI falls back to app icon.
    var iconImage: NSImage?

    // MARK: - Hashable / Equatable (exclude element and iconImage)
    static func == (lhs: HiddenMenuBarItem, rhs: HiddenMenuBarItem) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
