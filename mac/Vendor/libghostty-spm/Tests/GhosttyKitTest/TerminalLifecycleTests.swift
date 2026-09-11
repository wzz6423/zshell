@testable import GhosttyTerminal
import Testing

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
#endif

@MainActor
struct TerminalLifecycleTests {
    @Test
    func `failed surface creation does not retain bridge`() {
        let controller = TerminalController()
        let bridge = TerminalCallbackBridge()

        let surface = controller.createSurface(
            bridge: bridge,
            configuration: .init()
        ) { _ in }

        #expect(surface == nil)
        #expect(controller.retainedBridgeCount == 0)
    }

    @Test
    func `switching controllers removes bridge from old controller`() {
        let oldController = TerminalController()
        let newController = TerminalController()
        let coordinator = TerminalSurfaceCoordinator()

        coordinator.isAttached = { false }
        oldController.retain(coordinator.bridge)
        #expect(oldController.retainedBridgeCount == 1)

        coordinator.controller = oldController
        #expect(oldController.retainedBridgeCount == 0)

        oldController.retain(coordinator.bridge)
        #expect(oldController.retainedBridgeCount == 1)

        coordinator.controller = newController

        #expect(oldController.retainedBridgeCount == 0)
        #expect(newController.retainedBridgeCount == 0)
    }

    @Test
    func `free surface removes retained bridge`() {
        let controller = TerminalController()
        let coordinator = TerminalSurfaceCoordinator()

        coordinator.isAttached = { false }
        coordinator.controller = controller

        controller.retain(coordinator.bridge)
        #expect(controller.retainedBridgeCount == 1)

        coordinator.freeSurface()

        #expect(controller.retainedBridgeCount == 0)
    }

    @Test
    func `requested geometry gate suppresses duplicates and resets`() {
        var gate = TerminalRequestedGeometryGate()
        let initial = TerminalRequestedGeometry(
            scale: 2,
            pixelWidth: 1_600,
            pixelHeight: 1_200
        )

        let appliesInitial = gate.shouldApply(initial)
        let skipsDuplicate = !gate.shouldApply(initial)
        let appliesWidthChange = gate.shouldApply(.init(
            scale: 2,
            pixelWidth: 1_602,
            pixelHeight: 1_200
        ))
        let appliesHeightChange = gate.shouldApply(.init(
            scale: 2,
            pixelWidth: 1_600,
            pixelHeight: 1_202
        ))
        let appliesScaleChange = gate.shouldApply(.init(
            scale: 3,
            pixelWidth: 2_403,
            pixelHeight: 1_800
        ))

        #expect(appliesInitial)
        #expect(skipsDuplicate)
        #expect(appliesWidthChange)
        #expect(appliesHeightChange)
        #expect(appliesScaleChange)

        gate.reset()
        let appliesAfterReset = gate.shouldApply(initial)

        #expect(appliesAfterReset)
    }

    @Test
    func `suspended wakeup does not schedule render`() {
        let controller = TerminalController()
        var wakeups = 0

        controller.shouldProcessWakeup = { false }
        controller.onWakeup = {
            wakeups += 1
        }

        controller.handleWakeup()

        #expect(wakeups == 0)
    }

    @Test
    func `application active state controls immediate ticks`() async {
        let coordinator = TerminalSurfaceCoordinator()
        var renders = 0

        coordinator.isAttached = { true }
        coordinator.onPostRender = {
            renders += 1
        }

        coordinator.setApplicationActive(false)
        coordinator.requestImmediateTick()
        await Task.yield()

        #expect(renders == 0)

        coordinator.setApplicationActive(true)
        await Task.yield()

        #expect(renders == 1)
    }

    @Test
    func `render resource hooks follow display visibility edges`() {
        let coordinator = TerminalSurfaceCoordinator()
        coordinator.isAttached = { true }
        var transitions: [String] = []
        coordinator.onRenderSuspended = {
            transitions.append("suspend")
        }
        coordinator.onRenderResuming = {
            transitions.append("resume")
        }

        coordinator.setDisplayVisible(false)
        #expect(transitions == ["suspend"])

        coordinator.setDisplayVisible(true)
        #expect(transitions == ["suspend", "resume"])
    }

    #if canImport(AppKit) && !canImport(UIKit)
        @Test
        func `active Metal renderer scale updates its drawable size`() throws {
            let view = AppTerminalView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 600)
            )
            let metalLayer = try #require(view.layer as? CAMetalLayer)

            view.updateActiveRendererLayer(scale: 0.1)

            #expect(metalLayer.contentsScale == 0.1)
            #expect(metalLayer.drawableSize == CGSize(width: 80, height: 60))
        }

        @Test
        func `metric updates preserve compacted active Metal layer`() throws {
            let view = AppTerminalView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 600)
            )
            let metalLayer = try #require(view.layer as? CAMetalLayer)
            let compactDrawableSize = CGSize(width: 80, height: 60)
            view.rendererTargetsCompacted = true
            metalLayer.contentsScale = 0.1
            metalLayer.drawableSize = compactDrawableSize

            view.updateMetalLayerMetrics()

            #expect(metalLayer.contentsScale == 0.1)
            #expect(metalLayer.drawableSize == compactDrawableSize)
        }
    #endif
}
