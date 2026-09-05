#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    extension AppTerminalView {
        /// Ghostty keeps three IOSurface-backed frame states so GPU work can
        /// overlap. Occlusion stops new frames but intentionally retains those
        /// targets. Synchronously drawing three thumbnail frames advances
        /// through the whole swap chain and replaces every pane-sized target
        /// without resizing the terminal grid or its PTY.
        func compactRendererTargets() {
            guard !rendererTargetsCompacted,
                  let surface,
                  let layer
            else { return }

            let maximumDimension = max(layer.bounds.width, layer.bounds.height)
            guard maximumDimension > 0 else { return }

            let compactScale = max(
                1 / maximumDimension,
                min(layer.contentsScale, 64 / maximumDimension)
            )
            guard compactScale < layer.contentsScale else { return }

            // Retain one complete destination-tab frame before replacing the
            // renderer's full-size targets with thumbnails. It covers the
            // target refill when this surface returns from parking.
            capturePresentationFrame()
            rendererTargetsCompacted = true
            updateActiveRendererLayer(scale: compactScale)
            for _ in 0..<3 {
                surface.draw()
            }
        }

        /// Rebuild every full-size frame before Ghostty is told the surface is
        /// visible, preventing a thumbnail frame or incremental reallocations
        /// from appearing while the user switches tabs.
        func restoreRendererTargets() {
            let needsMetricRestore = rendererTargetsCompacted
            rendererTargetsCompacted = false
            if needsMetricRestore {
                updateMetalLayerMetrics()
            }
            guard let surface else { return }
            reattachPresentationCoverIfNeeded()
            for _ in 0..<3 {
                surface.draw()
            }
            // Drawing can replace the attached IOSurface layer, so put the
            // retained frame back above the final layer before AppKit commits
            // this layout pass.
            reattachPresentationCoverIfNeeded()
            releasePresentationCoverAfterRendererSettles()
        }

        /// Holds the last complete IOSurface while Ghostty refills resized or
        /// compacted renderer targets. The retained contents stay pixel-true
        /// at the top-left instead of stretching with the view's new bounds.
        func capturePresentationFrame() {
            guard let sourceLayer = layer,
                  let contents = sourceLayer.presentation()?.contents
                    ?? sourceLayer.contents
            else { return }

            presentationCoverGeneration &+= 1
            hasCapturedPresentationFrame = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            presentationCoverLayer.contents = contents
            presentationCoverLayer.contentsScale = sourceLayer.contentsScale
            presentationCoverLayer.frame = sourceLayer.bounds
            presentationCoverLayer.isHidden = false
            presentationCoverLayer.removeFromSuperlayer()
            sourceLayer.addSublayer(presentationCoverLayer)
            CATransaction.commit()
        }

        func reattachPresentationCoverIfNeeded() {
            guard hasCapturedPresentationFrame,
                  let layer
            else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            presentationCoverLayer.frame = layer.bounds
            presentationCoverLayer.isHidden = false
            if presentationCoverLayer.superlayer !== layer {
                presentationCoverLayer.removeFromSuperlayer()
                layer.addSublayer(presentationCoverLayer)
            }
            CATransaction.commit()
        }

        /// libghostty does not expose Metal command completion through its C
        /// surface API. Keep the retained frame for a few display intervals so
        /// Core Animation cannot select a partially refilled target.
        func releasePresentationCoverAfterRendererSettles() {
            guard hasCapturedPresentationFrame else { return }
            let generation = presentationCoverGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.075) { [weak self] in
                guard let self,
                      hasCapturedPresentationFrame,
                      presentationCoverGeneration == generation
                else { return }

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                presentationCoverLayer.isHidden = true
                presentationCoverLayer.removeFromSuperlayer()
                presentationCoverLayer.contents = nil
                CATransaction.commit()
                hasCapturedPresentationFrame = false
            }
        }
    }
#endif
