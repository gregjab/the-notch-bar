---
project: The Notch Bar
type: app
status: draft
date: 2026-04-11
---

# The Notch Bar: Requirements

## Problem Statement

On MacBook models with a notch display, macOS silently hides menu bar icons behind the notch when horizontal space runs out. There is no native way to access these hidden icons. Users with 15-20+ menu bar utilities (Tailscale, VPN, VoiceInk, etc.) hit this constantly, especially when travelling and working primarily on the laptop display.

Existing tools solve adjacent problems: Ice manages menu bar sections but has a utilitarian UI. boring.notch turns the notch into a rich interaction surface but has no awareness of hidden menu bar items.

The Notch Bar combines both: fork boring.notch as the aesthetic and feature platform, then add hidden menu bar icon detection and access as a first-class feature.

## Success Criteria

- All menu bar icons hidden behind the notch are detected and displayed in the notch panel
- Clicking a displayed icon triggers its native dropdown menu, identical to clicking it in the menu bar
- Hidden icon row only appears when icons are actually hidden (context-aware per display)
- Display connect/disconnect triggers dynamic re-evaluation
- All existing boring.notch features (media controls, HUD replacement, file shelf, battery, calendar, webcam) continue to work unchanged
- Public fork on GitHub under GPL-3.0

## Users and Stakeholders

- **Primary user:** Greg Butcher, technical PM travelling with a MacBook, relying on menu bar utilities for daily workflows
- **Secondary:** Anyone with a notch MacBook and too many menu bar items (public fork)

## Workflows

### Primary: Accessing hidden menu bar icons

1. User is on laptop display with 15+ menu bar items
2. macOS hides overflow items behind the notch
3. The Notch Bar detects hidden items via Accessibility API
4. Hidden icons appear as a persistent row at the top of the notch panel (both compact and expanded views)
5. User hovers/clicks notch to expand, clicks a hidden icon
6. Native dropdown menu opens, panel stays open behind it
7. User interacts with the dropdown normally, clicks away to dismiss

### Context-aware display switching

1. User connects an external display (all icons now visible in the wider menu bar)
2. The Notch Bar detects no hidden icons on the external display
3. Hidden icon row disappears from the panel
4. All other boring.notch features (media, shelf, HUD, etc.) continue working
5. User disconnects external display, icons overflow again
6. Hidden icon row reappears automatically

### Existing boring.notch workflows (preserved)

- Hover/click notch to expand panel
- Media playback controls (Apple Music, Spotify)
- Volume/brightness HUD replacement
- File shelf drag-and-drop with AirDrop
- Battery/charging indicator
- Calendar and reminders
- Webcam mirror
- Multi-display support

## Constraints

### Technical
- **Base:** Fork of boring.notch (GPL-3.0)
- **Language:** Swift, SwiftUI with AppKit interop (matching existing codebase)
- **macOS:** 14.0+ (Sonoma), matching boring.notch's current target
- **Detection approach:** AX API (Accessibility) as primary method, CGEvent synthesis as click-forwarding fallback. Not reusing Ice's section delimiter mechanism or original nook-fixer implementation code.
- **Permission:** Requires Accessibility permission (boring.notch may already request this for some features)
- **Reference material:** Ice fork (gregjab/nook-fixer-v2) and original nook-fixer OpenSpec docs (~/Marvins-Obsidian-Hub/50-59 LDR Labs/nook-fixer/openspec/) available for reference, not for code reuse

### Distribution
- Public fork on Greg's GitHub (gregjab)
- GPL-3.0 licence (inherited from boring.notch)
- Sparkle auto-update (already in boring.notch)

### Design
- No emoji in UI (global rule)
- Hidden icon row integrates naturally with boring.notch's existing aesthetic (black panel, spring animations, quad-curve notch shape)

## Scope

### In Scope (Phase 1)
- Fork boring.notch as "The Notch Bar"
- Hidden menu bar icon detection via AX API
- Persistent hidden icon row at top of notch panel (compact + expanded views)
- Click forwarding to trigger native dropdown menus (AX primary, CGEvent fallback)
- Context-aware display: row only appears when icons are actually hidden
- Dynamic re-evaluation on display connect/disconnect
- All existing boring.notch features preserved and functional

### Nice to Have (Phase 2+)
- Icon curation: manually hide/show/pin specific items
- Timezone widget (multi-timezone display for AU/JP/KR/MENA)
- Upstream boring.notch feature pulls

### Out of Scope
- Ice's menu bar appearance customisation (tints, borders, shapes)
- Ice's section delimiter mechanism
- Private distribution or Tailscale hosting
- iOS/iPadOS companion
- Mac App Store distribution
- Reuse of original nook-fixer implementation code

## Open Questions

1. Does boring.notch already request Accessibility permission for any of its existing features? If so, no additional permission gate needed.
2. How should the hidden icon row handle apps with animated or dynamically changing status icons? (e.g., upload progress indicators)
3. Should there be a maximum number of icons in the compact view row before it overflows or scrolls?
4. Naming in the UI and repo: "The Notch Bar" as display name, "the-notch-bar" as repo slug?

## Next Steps

1. Fork boring.notch to gregjab/the-notch-bar
2. Hand off to orchestrator skill for spec authoring, review, build, audit, QA pipeline
3. Phase 1 build: hidden icon detection and display within boring.notch's existing UI
4. QA on Greg's MacBook Air (notch display) with his actual menu bar setup
