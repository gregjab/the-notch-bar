//
//  HiddenIconRow.swift
//  boringNotch
//
//  Created for The Notch Bar: Phase 1 - Hidden Icon Display
//

import Defaults
import SwiftUI

struct HiddenIconRow: View {
    let items: [HiddenMenuBarItem]
    let onItemClick: (HiddenMenuBarItem) -> Void
    @EnvironmentObject var vm: BoringViewModel

    @State private var hoveredItemID: String?

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else if vm.notchState == .open {
            expandedLayout
        } else {
            compactLayout
        }
    }

    // MARK: - Compact Layout (closed state)

    private var compactLayout: some View {
        let iconSize = max(0, vm.effectiveClosedNotchHeight - 8)

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(items) { item in
                    iconButton(item: item, iconSize: iconSize)
                }
            }
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .accessibilityLabel("Hidden menu bar icons")
    }

    // MARK: - Expanded Layout (open state)

    private var expandedLayout: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(items) { item in
                        iconButton(item: item, iconSize: 22)
                            .help(item.appName)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(height: 28)

            Divider()
                .opacity(0.15)
        }
        .accessibilityLabel("Hidden menu bar icons")
    }

    // MARK: - Icon Button

    @ViewBuilder
    private func iconButton(item: HiddenMenuBarItem, iconSize: CGFloat) -> some View {
        Button {
            onItemClick(item)
        } label: {
            Group {
                if let iconImage = item.iconImage {
                    Image(nsImage: iconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if let bundleID = item.bundleIdentifier,
                          let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "app.fill")
                        .foregroundColor(.gray)
                }
            }
            .frame(width: iconSize, height: iconSize)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .brightness(hoveredItemID == item.id ? 0.2 : 0)
        }
        .buttonStyle(PlainButtonStyle())
        .help(item.appName)
        .onHover { isHovering in
            hoveredItemID = isHovering ? item.id : nil
        }
        .accessibilityLabel("\(item.appName) menu bar item")
        .accessibilityAddTraits(.isButton)
    }
}
