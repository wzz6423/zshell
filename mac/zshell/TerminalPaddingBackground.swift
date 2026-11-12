import AppKit
import GhosttyTerminal
import IOSurface

/// The pinned engine retains extension flags when switching to `background`.
/// Reuse its IOSurface without moving the grid or restarting the surface/PTY.
@MainActor
final class TerminalPaddingBackground {
    private let image = CALayer()
    private let border = CAShapeLayer()
    private let coverClip = CAShapeLayer()
    private weak var backing: CALayer?
    private weak var cover: CALayer?
    private var originalContentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var originalCoverMask: CALayer?
    private var observation: NSKeyValueObservation?
    private var previousBounds = CGRect.null
    private var previousScale: CGFloat = 0
    private var grid = CGRect.null
    private var color = NSColor.clear
    private var opacity = 1.0

    init() {
        image.contentsGravity = .resize
        border.fillRule = .evenOdd
    }

    func invalidateGeometry() { previousBounds = .null }

    func update(view: AppTerminalView, enabled: Bool, color: NSColor, opacity: Double) {
        guard enabled, let layer = view.layer else {
            reset()
            return
        }
        self.color = color
        self.opacity = opacity
        if backing !== layer {
            reset()
            backing = layer
            originalContentsRect = layer.contentsRect
            // Ghostty also assigns completed frames asynchronously on main.
            // Observing that assignment avoids showing the previous image.
            observation = layer.observe(\.contents, options: [.new]) { [weak self, weak view] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let view, self.backing === view.layer else { return }
                    self.update(view: view, enabled: true, color: self.color, opacity: self.opacity)
                }
            }
        }
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let bounds = layer.bounds
        guard bounds.width > 0, bounds.height > 0,
              let contents = layer.contents,
              CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID()
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let geometryChanged = previousBounds != bounds || previousScale != scale
        if geometryChanged {
            guard let size = view.viewportGridMetrics, size.columns > 0, size.rows > 0,
                  let first = view.readViewportText(row: 0, columns: 0..<1) else {
                CATransaction.commit()
                return
            }
            let width = CGFloat(size.columns) * CGFloat(size.cellWidthPixels) / scale
            let height = CGFloat(size.rows) * CGFloat(size.cellHeightPixels) / scale
            // `window-padding-balance = true` floors physical pixels and caps
            // the top at the explicit horizontal inset plus half a cell.
            let top = CGFloat(max(0, min(
                (Int(size.heightPixels) - Int(size.rows) * Int(size.cellHeightPixels)) / 2,
                (Int(20 * scale) + Int(size.cellWidthPixels)) / 2
            ))) / scale
            grid = CGRect(x: first.origin.x, y: bounds.height - top - height,
                          width: width, height: height)
            let screen = CGSize(width: CGFloat(size.widthPixels) / scale,
                                height: CGFloat(size.heightPixels) / scale)
            image.frame = grid
            image.contentsRect = CGRect(x: grid.minX / screen.width,
                                        y: (screen.height - top - height) / screen.height,
                                        width: width / screen.width, height: height / screen.height)
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(grid)
            border.frame = bounds
            border.path = path
            previousBounds = bounds
            previousScale = scale
        }
        // Zero contentsRect hides only the source image, preserving NSView
        // sublayers such as the OSC 9 progress bar. No pixel storage is copied.
        layer.contentsRect = .zero
        image.contentsScale = layer.contentsScale
        image.contents = contents
        border.fillColor = color.withAlphaComponent(opacity).cgColor
        if image.superlayer !== layer { layer.insertSublayer(image, at: 0) }
        if border.superlayer !== layer { layer.insertSublayer(border, above: image) }
        let nextCover = layer.sublayers?.first { $0 !== image && $0 !== border && $0.contents != nil }
        let coverChanged = cover !== nextCover
        if coverChanged {
            restoreCover()
            cover = nextCover
            originalCoverMask = nextCover?.mask
        }
        if let cover {
            if geometryChanged || coverChanged {
                coverClip.frame = cover.bounds
                coverClip.path = CGPath(rect: grid, transform: nil)
            }
            cover.mask = coverClip
        }
        CATransaction.commit()
    }

    func reset() {
        observation?.invalidate()
        observation = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backing?.contentsRect = originalContentsRect
        image.removeFromSuperlayer()
        image.contents = nil
        border.removeFromSuperlayer()
        restoreCover()
        backing = nil
        previousBounds = .null
        CATransaction.commit()
    }

    private func restoreCover() {
        if cover?.mask === coverClip { cover?.mask = originalCoverMask }
        originalCoverMask = nil
        cover = nil
    }
}
