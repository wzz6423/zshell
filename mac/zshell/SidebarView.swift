//
//  SidebarView.swift
//  zshell
//

import AppKit
import SwiftUI

/// The legacy workspace retains only its persisted width binding; the
/// sidebar contents and interaction are owned by the native view.
struct SidebarView: View {
    let manager: TerminalManager
    let tabDrag: TabSplitDragCoordinator
    let bottomBarHeight: CGFloat
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage("leftSidebarWidth") private var width: Double = 220

    var body: some View {
        ProjectSidebarRepresentable(manager: manager, tabDrag: tabDrag, bottomBarHeight: bottomBarHeight)
            .frame(width: width)
            .overlay(alignment: .trailing) {
                SidebarResizeHandle(
                    edge: .trailing,
                    width: $width,
                    range: (160 * settings.interfaceScale)...(400 * settings.interfaceScale),
                    defaultWidth: 220 * settings.interfaceScale,
                    fontSize: settings.sidebarFontSize
                )
            }
    }
}

struct ChromeIconButton: View {
    @ObservedObject private var settings = AppSettings.shared
    let systemImage: String
    let tooltip: LocalizedStringKey
    /// `nil` follows the interface scale from Appearance settings; explicit
    /// values are sized by the call site.
    var font: Font? = nil
    var iconSize: CGFloat? = nil
    var tooltipEdge: TooltipEdge = .below
    var tooltipAlignment: HorizontalAlignment = .trailing
    let action: () -> Void

    @State private var isHovering = false

    private var scale: CGFloat { CGFloat(settings.interfaceScale) }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(font ?? .system(size: 12 * scale, weight: .medium))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: iconSize ?? 16 * scale, height: iconSize ?? 16 * scale)
                .padding(4)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .tooltip(tooltip, edge: tooltipEdge, alignment: tooltipAlignment)
    }
}
