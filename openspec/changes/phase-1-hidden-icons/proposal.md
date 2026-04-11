# Phase 1: Hidden Menu Bar Icon Detection and Access

## Why

On MacBook models with a display notch, macOS silently hides menu bar icons that overflow behind the notch. There is no native mechanism to access these hidden icons. Users running 15-20+ menu bar utilities (Tailscale, VPN clients, VoiceInk, system monitors, etc.) lose access to critical controls whenever they work on the laptop display.

boring.notch already occupies the notch as an interactive panel with media controls, file shelf, HUD replacement, battery, calendar, and webcam. It is the natural surface to expose hidden menu bar items, but currently has no awareness of them.

This change adds hidden menu bar icon detection and access as a first-class feature of The Notch Bar fork.

## What Changes

1. **New subsystem: MenuBarItemDetector** - A singleton manager that enumerates running applications via the Accessibility API, discovers menu bar items hidden behind the notch dead zone, and publishes a per-screen list of hidden items. Refreshes on panel open, app launch/terminate, screen configuration change, and AX notification.

2. **New UI: HiddenIconRow** - A compact, horizontal row of clickable icons rendered at the top of the notch panel's header section in ContentView. Visible in both the closed (compact/live activity) state and the expanded (open) state. Conditionally rendered: only appears when hidden items exist for the current screen.

3. **New subsystem: Click forwarding and dismissal state** - When a user clicks a hidden icon in the row, the system performs AXPress on the original menu bar item element (with CGEvent mouse-click fallback), then enters a "dropdown-active" state that prevents the notch panel from auto-closing while the native dropdown menu is open.

## Capabilities

- Detect all menu bar icons hidden behind the MacBook notch on any connected display
- Display hidden icons as a persistent, scrollable row in the notch panel
- Forward clicks to trigger the native dropdown menu for each icon
- Dynamically re-evaluate on display connect/disconnect, app launch/quit, and panel open
- Distinguish between built-in display (notch present) and external displays (no notch, no hidden icons)
- Preserve all existing boring.notch features without modification

## Impact

### Files Modified

| File | Change |
|------|--------|
| `boringNotch/ContentView.swift` | Insert HiddenIconRow in NotchLayout header section |
| `boringNotch/enums/generic.swift` | No changes needed (row is inline, not a new tab) |
| `boringNotch/models/Constants.swift` | Add Defaults keys for hidden icon feature toggle |
| `boringNotch/models/BoringViewModel.swift` | Add `hiddenIconItems` published property, wire to detector |
| `boringNotch/boringNotchApp.swift` | Initialise MenuBarItemDetector, wire screen change events |
| `boringNotch/components/Notch/BoringHeader.swift` | Minor: ensure header accommodates icon row above it when open |

### Files Created

| File | Purpose |
|------|---------|
| `boringNotch/managers/MenuBarItemDetector.swift` | Singleton: AX enumeration, classification, refresh logic |
| `boringNotch/models/HiddenMenuBarItem.swift` | Data model for a hidden menu bar item |
| `boringNotch/components/Notch/HiddenIconRow.swift` | SwiftUI view: horizontal row of clickable hidden icons |
| `boringNotch/managers/ClickForwardingManager.swift` | AXPress / CGEvent click forwarding, dismissal state machine |

### Risk Areas

- **Accessibility permission**: boring.notch already uses AX via XPCHelperClient for HUD replacement. The new detection code runs in the main app process (not the XPC helper) because it needs to create AXUIElements from running app PIDs. AXIsProcessTrusted must be true for the main app.
- **AXExtrasMenuBar vs AXMenuBar**: The extras menu bar (right side, where third-party icons live) is a different AX element from the main menu bar (left side, app menus). Detection must target AXExtrasMenuBar specifically.
- **Stale elements**: If an app quits between detection and click, the AXUIElement becomes invalid. Must handle gracefully.
- **macOS Tahoe (26)**: CGWindowList reports all items as Control Centre-owned. The AX path handles this correctly since it queries per-PID, but the fallback click path must not rely on window ownership.
- **Panel auto-close conflict**: The existing hover-leave close behaviour will fight with native dropdown menus. The dismissal state model must suppress auto-close while a dropdown is active.

### No Impact On

- Media playback (MusicManager, NowPlayingController, Spotify/Apple Music controllers)
- File shelf (ShelfView, ShelfStateViewModel)
- HUD replacement (MediaKeyInterceptor, sneak peek system)
- Battery/calendar/webcam views
- Multi-display window management (one BoringViewModel per screen already exists)
- XPC helper process (detection runs in main app, not helper)
