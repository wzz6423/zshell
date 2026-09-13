//
//  SidebarResizeHandle.swift
//  zshell
//

import AppKit
import SwiftUI

/// Native resize strip mounted at a sidebar's inner edge.
struct SidebarResizeHandle: NSViewRepresentable {
    let edge: HorizontalEdge
    @Binding var width: Double
    let range: ClosedRange<Double>
    let defaultWidth: Double
    let fontSize: Double

    func makeNSView(context: Context) -> SidebarResizeHandleNSView {
        SidebarResizeHandleNSView(frame: .zero)
    }

    func updateNSView(_ view: SidebarResizeHandleNSView, context: Context) {
        let metrics = SidebarLayoutMetrics(fontSize: fontSize)
        let minimum = Double(metrics.minimumWidth(CGFloat(range.lowerBound)))
        view.update(
            edge: edge,
            width: width,
            range: minimum...range.upperBound,
            defaultWidth: defaultWidth,
            onWidthChange: { width = $0 }
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SidebarResizeHandleNSView,
        context: Context
    ) -> CGSize? {
        CGSize(width: 7, height: proposal.height ?? 0)
    }
}

final class SidebarResizeHandleNSView: NSView {
    private var edge = HorizontalEdge.trailing
    private var width: Double = 0
    private var range: ClosedRange<Double> = 0...0
    private var defaultWidth: Double = 0
    private var onWidthChange: ((Double) -> Void)?
    private var baselineWidth: Double?
    private var baselineMouseX: CGFloat?

    override var intrinsicContentSize: NSSize {
        NSSize(width: 7, height: NSView.noIntrinsicMetric)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .columnResize)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            setWidth(defaultWidth)
            return
        }
        baselineWidth = width
        baselineMouseX = NSEvent.mouseLocation.x
        NSCursor.columnResize.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let baselineWidth, let baselineMouseX else { return }
        let mouseDelta = NSEvent.mouseLocation.x - baselineMouseX
        let delta = edge == .trailing ? mouseDelta : -mouseDelta
        setWidth(baselineWidth + Double(delta))
        NSCursor.columnResize.set()
    }

    override func mouseUp(with event: NSEvent) {
        baselineWidth = nil
        baselineMouseX = nil
    }

    func update(
        edge: HorizontalEdge,
        width: Double,
        range: ClosedRange<Double>,
        defaultWidth: Double,
        onWidthChange: @escaping (Double) -> Void
    ) {
        self.edge = edge
        self.width = width
        self.range = range
        self.defaultWidth = defaultWidth
        self.onWidthChange = onWidthChange

        let clamped = clamp(width)
        if clamped != width {
            DispatchQueue.main.async { onWidthChange(clamped) }
        }
    }

    private func setWidth(_ proposedWidth: Double) {
        let clamped = clamp(proposedWidth)
        guard clamped != width else { return }
        width = clamped
        onWidthChange?(clamped)
    }

    private func clamp(_ proposedWidth: Double) -> Double {
        min(max(proposedWidth, range.lowerBound), range.upperBound)
    }
}
