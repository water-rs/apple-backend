// WuiGpuSurface.swift
// High-performance GPU rendering surface using wgpu
//
// # Layout Behavior
// GpuSurface stretches to fill available space by default (like SwiftUI's Color).
// Users can control size using the `.frame()` modifier externally.
//
// # Rendering
// Uses CAMetalLayer for zero-copy GPU rendering at up to 120fps.
// The Rust side owns wgpu Device/Queue/Surface and calls user's GpuRenderer callbacks.
//
// # HDR Support
// Configures CAMetalLayer for HDR when available using extended sRGB color space.

import CWaterUI
import Foundation
import Metal
import OSLog
import QuartzCore

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
    import CoreVideo
#endif

private struct WuiGpuSurfaceRenderOutcome: Sendable {
    let success: Bool
    let needsRedraw: Bool
}

private final class WuiGpuSurfaceRenderState: @unchecked Sendable {
    private final class BoolCompletionBox: @unchecked Sendable {
        let completion: (Bool) -> Void

        init(_ completion: @escaping (Bool) -> Void) {
            self.completion = completion
        }
    }

    private var ffiSurface: CWaterUI.WuiGpuSurface
    private let envPtr: OpaquePointer
    private var gpuState: OpaquePointer?
    private var isInitializing = false
    private var isActive = true
    private var renderInFlight = false
    private var externalRendering = false
    private var needsRender = true
    private var width: UInt32 = 0
    private var height: UInt32 = 0

    // Pointer/cursor state for GPU renderers
    private var pointerState = WuiPointerState(
        has_position: false,
        x: 0,
        y: 0,
        has_hit: false,
        hit_x: 0,
        hit_y: 0
    )

    // Gesture state for zoom/pan interactions
    private var gestureState = WuiGestureState(
        active: false,
        pinch_scale: 1.0,
        has_pinch_center: false,
        pinch_center_x: 0,
        pinch_center_y: 0,
        pan_offset_x: 0,
        pan_offset_y: 0,
        double_tap: false
    )

    private let lock = NSLock()

    init(ffiSurface: CWaterUI.WuiGpuSurface, envPtr: OpaquePointer) {
        self.ffiSurface = ffiSurface
        self.envPtr = envPtr
    }

    /// Update pointer position (in surface-local pixel coordinates).
    func updatePointerPosition(_ position: CGPoint?, scaleFactor: CGFloat) {
        lock.lock()
        needsRender = true
        if let pos = position {
            pointerState.has_position = true
            pointerState.x = Float(pos.x * scaleFactor)
            pointerState.y = Float(pos.y * scaleFactor)
        } else {
            pointerState.has_position = false
        }
        lock.unlock()
    }

    /// Update pointer hit state.
    func updatePointerHit(_ hit: Bool, origin: CGPoint?, scaleFactor: CGFloat) {
        lock.lock()
        needsRender = true
        if hit, let origin = origin {
            pointerState.has_hit = true
            pointerState.hit_x = Float(origin.x * scaleFactor)
            pointerState.hit_y = Float(origin.y * scaleFactor)
        } else if !hit {
            pointerState.has_hit = false
        }
        lock.unlock()
    }

    /// Update gesture state for pinch zoom.
    func updatePinchGesture(active: Bool, scale: CGFloat, center: CGPoint?, scaleFactor: CGFloat) {
        lock.lock()
        needsRender = true
        gestureState.active = active
        gestureState.pinch_scale = Float(scale)
        if let center = center {
            gestureState.has_pinch_center = true
            gestureState.pinch_center_x = Float(center.x * scaleFactor)
            gestureState.pinch_center_y = Float(center.y * scaleFactor)
        } else {
            gestureState.has_pinch_center = false
        }
        lock.unlock()
    }

    /// Update gesture state for pan.
    func updatePanGesture(active: Bool, offsetX: CGFloat, offsetY: CGFloat, scaleFactor: CGFloat) {
        lock.lock()
        needsRender = true
        gestureState.active = active
        gestureState.pan_offset_x = Float(offsetX * scaleFactor)
        gestureState.pan_offset_y = Float(offsetY * scaleFactor)
        lock.unlock()
    }

    /// Signal a double-tap gesture.
    func triggerDoubleTap() {
        lock.lock()
        needsRender = true
        gestureState.double_tap = true
        lock.unlock()
    }

    /// Clear double-tap flag (called after rendering).
    private func clearDoubleTap() {
        gestureState.double_tap = false
    }

    /// Reset gesture state when gesture ends.
    func resetGestureState() {
        lock.lock()
        needsRender = true
        gestureState.active = false
        gestureState.pinch_scale = 1.0
        gestureState.has_pinch_center = false
        gestureState.pan_offset_x = 0
        gestureState.pan_offset_y = 0
        lock.unlock()
    }

    /// Send current pointer + gesture state to the GPU surface before rendering.
    private func syncInputState() {
        guard let state = gpuState else { return }
        let input = WuiGpuSurfaceInput(pointer: pointerState, gesture: gestureState)
        waterui_gpu_surface_set_input(state, input)
        // Clear double_tap after sending (it's a one-frame signal)
        clearDoubleTap()
    }

    func updateSize(width: UInt32, height: UInt32) {
        lock.lock()
        needsRender = true
        self.width = width
        self.height = height
        lock.unlock()
    }

    /// Read Rust-resolved dynamic range preference from GpuSurface.
    /// Must be called before `waterui_gpu_surface_init` consumes `ffiSurface`.
    func surfaceDynamicRangePreference() -> WuiDynamicRangeMode {
        lock.lock()
        defer { lock.unlock() }

        let preference = withUnsafeMutablePointer(to: &ffiSurface) { surfacePtr in
            waterui_gpu_surface_hdr_preference(surfacePtr)
        }
        return preference.resolved_prefers_hdr ? .high : .standard
    }

    func initializeIfNeeded(
        layerPtr: UnsafeMutableRawPointer,
        width: UInt32,
        height: UInt32,
        completion: @escaping (Bool) -> Void
    ) {
        lock.lock()
        if !isActive {
            lock.unlock()
            completion(false)
            return
        }

        self.width = width
        self.height = height

        if gpuState != nil {
            lock.unlock()
            completion(true)
            return
        }

        if isInitializing {
            lock.unlock()
            return
        }

        isInitializing = true
        lock.unlock()

        let completionBox = BoolCompletionBox(completion)
        let layerAddr = Int(bitPattern: layerPtr)

        WuiSharedRenderQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completionBox.completion(false) }
                return
            }

            guard let layerPtr = UnsafeMutableRawPointer(bitPattern: layerAddr) else {
                self.lock.lock()
                self.isInitializing = false
                self.lock.unlock()
                DispatchQueue.main.async { completionBox.completion(false) }
                return
            }

            let state: OpaquePointer? = withUnsafeMutablePointer(to: &self.ffiSurface) {
                surfacePtr in
                waterui_gpu_surface_init(surfacePtr, layerPtr, width, height, self.envPtr)
            }

            self.lock.lock()
            self.isInitializing = false

            guard self.isActive else {
                self.lock.unlock()
                if let state { waterui_gpu_surface_drop(state) }
                return
            }

            self.gpuState = state
            let success = (state != nil)
            self.lock.unlock()

            DispatchQueue.main.async {
                completionBox.completion(success)
            }
        }
    }

    @discardableResult
    func requestRender(
        force: Bool = false,
        completion: @escaping @Sendable (WuiGpuSurfaceRenderOutcome) -> Void
    ) -> Bool {
        lock.lock()
        if !isActive || externalRendering {
            lock.unlock()
            return false
        }

        if !force {
            if !needsRender {
                guard let state = gpuState, waterui_gpu_surface_needs_redraw(state) else {
                    lock.unlock()
                    return false
                }
                needsRender = true
            }
        }

        guard let state = gpuState, width > 0, height > 0, !renderInFlight else {
            lock.unlock()
            return false
        }

        renderInFlight = true
        needsRender = false
        let stateAddr = Int(bitPattern: state)
        let width = self.width
        let height = self.height
        lock.unlock()

        WuiSharedRenderQueue.async { [weak self] in
            guard let self else { return }
            // Sync pointer and gesture state before rendering
            self.syncInputState()
            guard let state = OpaquePointer(bitPattern: stateAddr) else {
                self.lock.lock()
                self.renderInFlight = false
                self.lock.unlock()
                DispatchQueue.main.async {
                    completion(WuiGpuSurfaceRenderOutcome(success: false, needsRedraw: false))
                }
                return
            }
            let result = waterui_gpu_surface_render(state, width, height)
            self.lock.lock()
            self.renderInFlight = false
            if !result.ok || result.needs_redraw {
                self.needsRender = true
            }
            let shouldContinue = self.needsRender
            self.lock.unlock()

            DispatchQueue.main.async {
                completion(
                    WuiGpuSurfaceRenderOutcome(success: result.ok, needsRedraw: shouldContinue)
                )
            }
        }
        return true
    }

    func waitForIdle() {
        WuiSharedRenderQueue.drain()
    }

    private func hasRenderInFlight() -> Bool {
        lock.lock()
        let inFlight = renderInFlight
        lock.unlock()
        return inFlight
    }

    func waitForInFlightRenderSynchronously() {
        let shouldWait = hasRenderInFlight()

        if shouldWait {
            WuiSharedRenderQueue.drain()
        }
    }

    func waitForInFlightRender() async {
        let shouldWait = hasRenderInFlight()

        guard shouldWait else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WuiSharedRenderQueue.barrierAsync {
                continuation.resume()
            }
        }
    }

    func setExternalRendering(_ enabled: Bool) {
        lock.lock()
        externalRendering = enabled
        lock.unlock()
    }

    func renderToMetalTexture(texturePtr: UnsafeMutableRawPointer, width: UInt32, height: UInt32) -> Bool {
        lock.lock()
        if !isActive {
            lock.unlock()
            return false
        }
        let inFlight = renderInFlight
        lock.unlock()

        if inFlight {
            waitForIdle()
        }

        lock.lock()
        guard isActive, let state = gpuState, width > 0, height > 0 else {
            lock.unlock()
            return false
        }
        if renderInFlight {
            lock.unlock()
            return false
        }
        renderInFlight = true
        lock.unlock()

        let renderBlock = { [weak self] () -> Bool in
            guard let self else { return false }
            self.syncInputState()
            let ok = waterui_gpu_surface_render_to_metal_texture(state, texturePtr, width, height)
            self.lock.lock()
            self.renderInFlight = false
            self.lock.unlock()
            return ok
        }

        if WuiSharedRenderQueue.isCurrent {
            return renderBlock()
        }

        return WuiSharedRenderQueue.sync { renderBlock() }
    }

    /// Get current state and initialization status (thread-safe).
    private func getStateInfo() -> (state: OpaquePointer?, isInitializing: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (gpuState, isInitializing)
    }

    /// Await GPU setup completion and first frame render.
    /// This is used to ensure all GpuSurfaces are ready before showing the window.
    func awaitReady() async -> Bool {
        // Wait for state to be available
        var state: OpaquePointer?
        while true {
            let info = getStateInfo()
            state = info.state

            if state != nil {
                break
            }
            if !info.isInitializing {
                return false
            }
            // Poll every 10ms while initializing
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        guard let state else { return false }
        await waitForInFlightRender()
        let stateAddr = Int(bitPattern: state)

        // Call await_ready on render queue and forward success to caller.
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            WuiSharedRenderQueue.async {
                let ok = waterui_gpu_surface_await_ready(OpaquePointer(bitPattern: stateAddr))
                continuation.resume(returning: ok)
            }
        }
    }

    func awaitReadySynchronously() -> Bool {
        var state: OpaquePointer?
        while true {
            let info = getStateInfo()
            state = info.state

            if state != nil {
                break
            }
            if !info.isInitializing {
                return false
            }
            _ = RunLoop.current.run(mode: .default, before: .distantFuture)
        }

        guard let state else { return false }
        waitForInFlightRenderSynchronously()
        let stateAddr = Int(bitPattern: state)
        return WuiSharedRenderQueue.sync {
            waterui_gpu_surface_await_ready(OpaquePointer(bitPattern: stateAddr))
        }
    }

    func shutdown() {
        lock.lock()
        isActive = false
        let state = gpuState
        gpuState = nil
        lock.unlock()

        WuiSharedRenderQueue.barrier {
            if let state { waterui_gpu_surface_drop(state) }
        }
    }
}

/// High-performance GPU rendering surface using wgpu.
/// Uses CAMetalLayer with CADisplayLink for 120fps rendering.
@MainActor
final class WuiGpuSurface: PlatformView, WuiComponent, WuiFirstPaintReadyParticipant, @unchecked Sendable {
    static var rawId: CWaterUI.WuiTypeId { waterui_gpu_surface_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let renderState: WuiGpuSurfaceRenderState

    /// The CAMetalLayer for GPU rendering
    private var metalLayer: CAMetalLayer!

	    /// Display link for frame sync (120fps capable)
	    #if canImport(UIKit)
	        private var displayLink: CADisplayLink?
	    #elseif canImport(AppKit)
	        private var displayLink: CADisplayLink?
	        private var trackingArea: NSTrackingArea?
	        private weak var observedWindow: NSWindow?
	        private var windowObservers: [NSObjectProtocol] = []
	    #endif

	    #if canImport(UIKit)
	        private var appObservers: [NSObjectProtocol] = []
	    #endif

    /// Whether we've initialized the GPU resources
    private var isGpuInitialized = false
    private var externalRendering = false
    private var externalRenderingCount = 0
    private let externalLock = NSLock()
    private var captureSuppressionCount = 0
    private let captureSuppressionLock = NSLock()
    private var keepRedrawing = false

    /// Current pointer pressed state (for tracking press origin)
    private var pressOrigin: CGPoint?

    /// Content scale factor for high-DPI displays
    private var currentScaleFactor: CGFloat = 1.0
    private var configuredDynamicRangeMode: WuiDynamicRangeMode?
    private let surfaceDynamicRangePreference: WuiDynamicRangeMode
    private var pictureInPictureHostBridge: WuiWaterKitVideoPictureInPictureHostBridge?

    /// Gesture tracking state
    private var gestureStartScale: CGFloat = 1.0
    private var cumulativeScale: CGFloat = 1.0
    private var gesturePanOffset: CGPoint = .zero

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        let ffiSurface = waterui_force_as_gpu_surface(anyview)
        let pictureInPictureHostId = ffiSurface.has_picture_in_picture_host_id
            ? ffiSurface.picture_in_picture_host_id
            : nil
        self.init(
            stretchAxis: stretchAxis,
            ffiSurface: ffiSurface,
            pictureInPictureHostId: pictureInPictureHostId,
            envPtr: env.inner
        )
    }

    // MARK: - Designated Init

		    init(
                stretchAxis: WuiStretchAxis,
                ffiSurface: CWaterUI.WuiGpuSurface,
                pictureInPictureHostId: UInt64?,
                envPtr: OpaquePointer
            ) {
		        self.stretchAxis = stretchAxis
		        let renderState = WuiGpuSurfaceRenderState(ffiSurface: ffiSurface, envPtr: envPtr)
		        self.renderState = renderState
		        self.surfaceDynamicRangePreference = renderState.surfaceDynamicRangePreference()

	        super.init(frame: .zero)

	        setupMetalLayer()
	        setupPointerTracking()
	        setupLifecycleObservers()
            if let pictureInPictureHostId {
                pictureInPictureHostBridge = WuiWaterKitVideoPictureInPictureHostBridge(
                    hostId: pictureInPictureHostId,
                    surface: self
                )
            }
	    }

	    private func setupLifecycleObservers() {
	        #if canImport(UIKit)
	            let center = NotificationCenter.default
	            appObservers.append(
                center.addObserver(
                    forName: UIApplication.willResignActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.updateDisplayLinkState()
                    }
                }
            )
            appObservers.append(
                center.addObserver(
                    forName: UIApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.updateDisplayLinkState()
                    }
                }
            )
        #endif
    }

    // MARK: - Pointer Tracking Setup

    private func setupPointerTracking() {
        #if canImport(UIKit)
            // iOS/iPadOS: Add hover gesture for pointer tracking (iPadOS with trackpad/mouse)
            if #available(iOS 13.0, *) {
                let hoverGesture = UIHoverGestureRecognizer(
                    target: self, action: #selector(handleHover(_:)))
                addGestureRecognizer(hoverGesture)
            }

            // Add pinch gesture for zoom
            let pinchGesture = UIPinchGestureRecognizer(
                target: self, action: #selector(handlePinch(_:)))
            addGestureRecognizer(pinchGesture)

            // Add pan gesture for chart panning
            let panGesture = UIPanGestureRecognizer(
                target: self, action: #selector(handlePan(_:)))
            panGesture.minimumNumberOfTouches = 2  // Require 2 fingers to avoid conflict with scroll
            panGesture.cancelsTouchesInView = false
            addGestureRecognizer(panGesture)

            // Add double-tap gesture for reset
            let doubleTapGesture = UITapGestureRecognizer(
                target: self, action: #selector(handleDoubleTap(_:)))
            doubleTapGesture.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTapGesture)

            // Allow simultaneous gesture recognition
            pinchGesture.delegate = self
            panGesture.delegate = self
        #elseif canImport(AppKit)
            // macOS: Tracking area is updated in updateTrackingAreas()
            // Add magnification gesture for zoom
            let magnifyGesture = NSMagnificationGestureRecognizer(
                target: self, action: #selector(handleMagnification(_:)))
            addGestureRecognizer(magnifyGesture)

            // Add pan gesture for chart panning (scroll gesture)
            // Note: On macOS, we use scroll events instead of a separate pan gesture
        #endif
    }

    #if canImport(UIKit)
        @available(iOS 13.0, *)
        @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
            switch gesture.state {
            case .began, .changed:
                let location = gesture.location(in: self)
                renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
                renderFrame()
            case .ended, .cancelled:
                renderState.updatePointerPosition(nil, scaleFactor: currentScaleFactor)
                renderFrame()
            default:
                break
            }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            if let touch = touches.first {
                let location = touch.location(in: self)
                pressOrigin = location
                renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
                renderState.updatePointerHit(true, origin: location, scaleFactor: currentScaleFactor)
                renderFrame()
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesMoved(touches, with: event)
            if let touch = touches.first {
                let location = touch.location(in: self)
                renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
                renderFrame()
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            renderState.updatePointerHit(false, origin: nil, scaleFactor: currentScaleFactor)
            pressOrigin = nil
            renderFrame()
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            renderState.updatePointerHit(false, origin: nil, scaleFactor: currentScaleFactor)
            pressOrigin = nil
            renderFrame()
        }

        // MARK: - Gesture Handlers (iOS)

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            let center = gesture.location(in: self)

            switch gesture.state {
            case .began:
                gestureStartScale = cumulativeScale
                renderState.updatePinchGesture(
                    active: true,
                    scale: cumulativeScale,
                    center: center,
                    scaleFactor: currentScaleFactor
                )
            case .changed:
                let newScale = gestureStartScale * gesture.scale
                cumulativeScale = max(0.1, min(newScale, 10.0))  // Clamp scale
                renderState.updatePinchGesture(
                    active: true,
                    scale: cumulativeScale,
                    center: center,
                    scaleFactor: currentScaleFactor
                )
            case .ended, .cancelled:
                renderState.updatePinchGesture(
                    active: false,
                    scale: cumulativeScale,
                    center: nil,
                    scaleFactor: currentScaleFactor
                )
            default:
                break
            }
            renderFrame()
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: self)

            switch gesture.state {
            case .began:
                gesturePanOffset = .zero
                renderState.updatePanGesture(
                    active: true,
                    offsetX: 0,
                    offsetY: 0,
                    scaleFactor: currentScaleFactor
                )
            case .changed:
                gesturePanOffset = CGPoint(x: translation.x, y: translation.y)
                renderState.updatePanGesture(
                    active: true,
                    offsetX: translation.x,
                    offsetY: translation.y,
                    scaleFactor: currentScaleFactor
                )
            case .ended, .cancelled:
                renderState.updatePanGesture(
                    active: false,
                    offsetX: translation.x,
                    offsetY: translation.y,
                    scaleFactor: currentScaleFactor
                )
                gesturePanOffset = .zero
            default:
                break
            }
            renderFrame()
        }

        @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .recognized {
                // Reset zoom/pan state
                cumulativeScale = 1.0
                gesturePanOffset = .zero
                renderState.triggerDoubleTap()
                renderState.resetGestureState()
                renderFrame()
            }
        }
    #elseif canImport(AppKit)
	        override func updateTrackingAreas() {
	            super.updateTrackingAreas()
	            guard trackingArea == nil else { return }
	            let options: NSTrackingArea.Options = [
	                .mouseEnteredAndExited,
	                .mouseMoved,
	                .activeInKeyWindow,
	                .inVisibleRect,
	            ]
	            let area = NSTrackingArea(
	                rect: .zero,
	                options: options,
	                owner: self,
	                userInfo: nil
	            )
	            trackingArea = area
	            addTrackingArea(area)
	        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            let location = convert(event.locationInWindow, from: nil)
            renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
            renderFrame()
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            let location = convert(event.locationInWindow, from: nil)
            renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
            renderFrame()
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            renderState.updatePointerPosition(nil, scaleFactor: currentScaleFactor)
            renderFrame()
        }

        override func mouseDragged(with event: NSEvent) {
            super.mouseDragged(with: event)
            let location = convert(event.locationInWindow, from: nil)
            renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
            renderFrame()
        }

        override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            renderState.updatePointerHit(false, origin: nil, scaleFactor: currentScaleFactor)
            pressOrigin = nil
            renderFrame()
        }

        override var acceptsFirstResponder: Bool { true }

        // MARK: - Gesture Handlers (macOS)

        @objc private func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
            let center = convert(gesture.location(in: self), from: nil)

            switch gesture.state {
            case .began:
                gestureStartScale = cumulativeScale
                renderState.updatePinchGesture(
                    active: true,
                    scale: cumulativeScale,
                    center: center,
                    scaleFactor: currentScaleFactor
                )
            case .changed:
                let newScale = gestureStartScale * (1.0 + gesture.magnification)
                cumulativeScale = max(0.1, min(newScale, 10.0))  // Clamp scale
                renderState.updatePinchGesture(
                    active: true,
                    scale: cumulativeScale,
                    center: center,
                    scaleFactor: currentScaleFactor
                )
            case .ended, .cancelled:
                renderState.updatePinchGesture(
                    active: false,
                    scale: cumulativeScale,
                    center: nil,
                    scaleFactor: currentScaleFactor
                )
            default:
                break
            }
            renderFrame()
        }

        override func scrollWheel(with event: NSEvent) {
            // When hosted inside NSScrollView, keep native scrolling as the default.
            // Hold Option to explicitly route wheel/trackpad delta to the GPU gesture channel.
            let hasScrollableAncestor = enclosingScrollView != nil
            let explicitSurfacePan = event.modifierFlags.contains(.option)
            if hasScrollableAncestor && !explicitSurfacePan {
                super.scrollWheel(with: event)
                return
            }

            super.scrollWheel(with: event)

            // Handle scroll wheel for panning (with Option key or trackpad)
            // Note: deltaX/deltaY are in points
            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY

            // Check for scroll gesture phase
            switch event.phase {
            case .began:
                gesturePanOffset = .zero
                renderState.updatePanGesture(
                    active: true,
                    offsetX: deltaX,
                    offsetY: deltaY,
                    scaleFactor: currentScaleFactor
                )
            case .changed:
                gesturePanOffset = CGPoint(
                    x: gesturePanOffset.x + deltaX,
                    y: gesturePanOffset.y + deltaY
                )
                renderState.updatePanGesture(
                    active: true,
                    offsetX: gesturePanOffset.x,
                    offsetY: gesturePanOffset.y,
                    scaleFactor: currentScaleFactor
                )
            case .ended, .cancelled:
                renderState.updatePanGesture(
                    active: false,
                    offsetX: gesturePanOffset.x,
                    offsetY: gesturePanOffset.y,
                    scaleFactor: currentScaleFactor
                )
                gesturePanOffset = .zero
            default:
                // Handle scroll events without phases (e.g., mouse wheel)
                if event.phase == [] && event.momentumPhase == [] {
                    // Immediate scroll event - treat as one-shot pan
                    renderState.updatePanGesture(
                        active: true,
                        offsetX: deltaX,
                        offsetY: deltaY,
                        scaleFactor: currentScaleFactor
                    )
                    renderState.updatePanGesture(
                        active: false,
                        offsetX: deltaX,
                        offsetY: deltaY,
                        scaleFactor: currentScaleFactor
                    )
                }
            }
            renderFrame()
        }

	        // Double-click to reset zoom/pan
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            super.mouseDown(with: event)
            let location = convert(event.locationInWindow, from: nil)
            pressOrigin = location
            renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
            renderState.updatePointerHit(true, origin: location, scaleFactor: currentScaleFactor)
            renderFrame()

            // Check for double-click
            if event.clickCount == 2 {
                cumulativeScale = 1.0
                gesturePanOffset = .zero
                renderState.triggerDoubleTap()
                renderState.resetGestureState()
                renderFrame()
            }
        }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Metal Layer Setup

    private func setupMetalLayer() {
        metalLayer = CAMetalLayer()

        // Get the default Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            Logger.waterui.error("[WuiGpuSurface] Failed to create Metal device")
            return
        }

        metalLayer.device = device
        metalLayer.framebufferOnly = false  // Allow texture readback for preview capture
        // Keep drawable count low for on-demand surfaces (memory + drawable pressure).
        metalLayer.maximumDrawableCount = 2
        metalLayer.isOpaque = false  // Allow transparency for compositing with background
        #if canImport(UIKit)
            metalLayer.backgroundColor = UIColor.clear.cgColor  // Ensure no black background
        #elseif canImport(AppKit)
            metalLayer.backgroundColor = NSColor.clear.cgColor  // Ensure no black background
        #endif

        // Use Rust-resolved preference immediately so layer format always matches
        // the swapchain format selection in `waterui_gpu_surface_init`.
        configureDynamicRange(surfaceDynamicRangePreference)

        #if canImport(UIKit)
            // iOS/tvOS: Add metal layer as sublayer
            layer.addSublayer(metalLayer)
        #elseif canImport(AppKit)
            // macOS: Need to set wantsLayer and add sublayer
            wantsLayer = true
            if self.layer == nil {
                self.layer = CALayer()
            }
            self.layer?.backgroundColor = NSColor.clear.cgColor
            self.layer?.addSublayer(metalLayer)
        #endif
    }

    /// Configure the metal layer for dynamic range rendering.
    private func configureDynamicRange(_ mode: WuiDynamicRangeMode) {
        applyDynamicRange(mode, to: self)
        applyDynamicRange(mode, to: metalLayer)

        guard configuredDynamicRangeMode != mode else { return }
        guard !isGpuInitialized else { return }

        if mode == .high {
            // HDR surface (must match Rust-side preferred format selection).
            metalLayer.pixelFormat = .rgba16Float
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            metalLayer.wantsExtendedDynamicRangeContent = true
        } else {
            // Force SDR for this subtree.
            metalLayer.pixelFormat = .bgra8Unorm_srgb
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            metalLayer.wantsExtendedDynamicRangeContent = false
        }
        let bytesPerPixel = (mode == .high) ? 8 : 4
        let modeLabel = (mode == .high) ? "high" : "standard"
        Logger.waterui.info(
            "[WuiGpuSurface] dynamicRange=\(modeLabel, privacy: .public) pixelFormat=\(self.metalLayer.pixelFormat.rawValue, privacy: .public) bytesPerPixel=\(bytesPerPixel, privacy: .public)"
        )
        configuredDynamicRangeMode = mode
    }

    // MARK: - GPU Initialization

    private func initializeGpuIfNeeded() {
        guard bounds.width > 0 && bounds.height > 0 else { return }

        // Rust is the source of truth for swapchain format; layer follows exactly.
        configureDynamicRange(surfaceDynamicRangePreference)

        #if canImport(UIKit)
            currentScaleFactor = contentScaleFactor
        #elseif canImport(AppKit)
            currentScaleFactor =
                window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
        #endif

        let width = UInt32(bounds.width * currentScaleFactor)
        let height = UInt32(bounds.height * currentScaleFactor)

        renderState.updateSize(width: width, height: height)

        // Update metal layer frame and drawable size
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        metalLayer.contentsScale = currentScaleFactor

        // Get pointer to metal layer for wgpu surface creation
        let layerPtr = Unmanaged.passUnretained(metalLayer).toOpaque()

	        guard !isGpuInitialized else { return }
	        renderState.initializeIfNeeded(layerPtr: layerPtr, width: width, height: height) {
	            [weak self] success in
	            guard let self else { return }
	            guard success else { return }
	            self.isGpuInitialized = true
            self.renderInitialFrame()
	        }
	    }

    // MARK: - Display Link

    #if canImport(UIKit)
        private func startDisplayLink() {
            guard displayLink == nil else { return }
            displayLink = CADisplayLink(target: self, selector: #selector(render))

            // Request up to 120fps on ProMotion displays
            if #available(iOS 15.0, tvOS 15.0, *) {
                displayLink?.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 60,
                    maximum: 120,
                    preferred: 120
                )
            }

            displayLink?.add(to: .main, forMode: .common)
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func render() {
            renderFrame()
        }
	    #elseif canImport(AppKit)
	        private func startDisplayLink() {
	            guard displayLink == nil else { return }
	            let link: CADisplayLink
	            if let window {
	                link = window.displayLink(target: self, selector: #selector(render))
	            } else if let screen = NSScreen.main {
	                link = screen.displayLink(target: self, selector: #selector(render))
	            } else {
	                return
	            }

	            // Request up to 120fps on ProMotion displays, mirroring the
	            // UIKit path: without an explicit range the panel is free to
	            // stay at a lower cadence.
	            link.preferredFrameRateRange = CAFrameRateRange(
	                minimum: 60,
	                maximum: 120,
	                preferred: 120
	            )

	            link.add(to: .main, forMode: .common)
	            displayLink = link
	        }

	        private func stopDisplayLink() {
	            displayLink?.invalidate()
	            displayLink = nil
	        }

	        @objc private func render() {
	            renderFrame()
	        }
	    #endif

    private func renderFrame(force: Bool = false) {
        let started = renderState.requestRender(force: force) { [weak self] outcome in
            guard let self else { return }
            MainActor.assumeIsolated {
                // Keep driving on display-sync while renderer requests another frame,
                // or when a transient render failure asks for retry.
                self.keepRedrawing = outcome.needsRedraw || !outcome.success
                self.updateDisplayLinkState()
            }
        }
        if !started {
            updateDisplayLinkState()
        }
    }

    private func renderInitialFrame() {
        renderFrame(force: true)
    }

	    private func isEffectivelyVisible() -> Bool {
	        #if canImport(UIKit)
	            guard window != nil else { return false }
	            guard !isHidden, alpha > 0 else { return false }
	            return UIApplication.shared.applicationState == .active
	        #elseif canImport(AppKit)
	            guard let window else { return false }
	            guard !isHidden, alphaValue > 0 else { return false }
	            if window.isMiniaturized { return false }
	            if !window.occlusionState.contains(.visible) { return false }
	            return true
	        #else
	            return true
	        #endif
	    }

    private func updateDisplayLinkState() {
        let shouldTick = keepRedrawing
        guard shouldTick else {
            stopDisplayLink()
            return
        }
        guard !externalRendering, isGpuInitialized, isEffectivelyVisible() else {
            stopDisplayLink()
            return
        }
        startDisplayLink()
    }

	    func setExternalRendering(_ enabled: Bool) {
	        externalRendering = enabled
	        renderState.setExternalRendering(enabled)
	        if enabled {
	            stopDisplayLink()
	        } else if isGpuInitialized {
	            updateDisplayLinkState()
	        }
	    }

    func beginExternalRendering() {
        externalLock.lock()
        externalRenderingCount += 1
        let shouldEnable = externalRenderingCount == 1
        externalLock.unlock()
        if shouldEnable {
            setExternalRendering(true)
            renderState.waitForInFlightRenderSynchronously()
        }
    }

    func endExternalRendering() {
        externalLock.lock()
        if externalRenderingCount > 0 {
            externalRenderingCount -= 1
        }
        let shouldDisable = externalRenderingCount == 0
        externalLock.unlock()
        if shouldDisable {
            setExternalRendering(false)
        }
    }

    private func setMetalLayerHidden(_ hidden: Bool) {
        guard metalLayer.isHidden != hidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.isHidden = hidden
        CATransaction.commit()
    }

    func beginCaptureSuppression() {
        captureSuppressionLock.lock()
        captureSuppressionCount += 1
        let shouldHide = captureSuppressionCount == 1
        captureSuppressionLock.unlock()
        if shouldHide {
            setMetalLayerHidden(true)
        }
    }

    func endCaptureSuppression() {
        captureSuppressionLock.lock()
        if captureSuppressionCount > 0 {
            captureSuppressionCount -= 1
        }
        let shouldShow = captureSuppressionCount == 0
        captureSuppressionLock.unlock()
        if shouldShow {
            setMetalLayerHidden(false)
        }
    }

    nonisolated func renderToMetalTexture(
        texture: MTLTexture,
        width: UInt32,
        height: UInt32
    ) -> Bool {
        let texturePtr = Unmanaged.passUnretained(texture).toOpaque()
        return renderState.renderToMetalTexture(texturePtr: texturePtr, width: width, height: height)
    }

    func prepareForReady() {
        #if canImport(UIKit)
            setNeedsLayout()
            layoutIfNeeded()
        #elseif canImport(AppKit)
            needsLayout = true
            layoutSubtreeIfNeeded()
        #endif
    }

    // MARK: - Async Ready

    /// Wait for GPU setup and first frame to complete.
    /// Call this before showing the window to prevent flicker.
    func waitForReady() async -> Bool {
        await renderState.awaitReady()
    }

    func waitForReadySynchronously() -> Bool {
        renderState.awaitReadySynchronously()
    }

    func participatesInFirstPaintReady() -> Bool {
        #if canImport(UIKit)
            guard window != nil else { return false }
            guard !isHidden, alpha > 0.01 else { return false }
            guard bounds.width > 0.5, bounds.height > 0.5 else { return false }
            return true
        #elseif canImport(AppKit)
            guard window != nil else { return false }
            guard !isHidden, alphaValue > 0.01 else { return false }
            guard bounds.width > 0.5, bounds.height > 0.5 else { return false }
            return true
        #else
            return true
        #endif
    }

    // MARK: - WuiComponent

    private func resolvedProposalDimension(_ value: Float?) -> CGFloat {
        guard let value else { return 0 }
        let resolved = CGFloat(value)
        precondition(!resolved.isNaN, "WuiGpuSurface received NaN proposal dimension")
        precondition(resolved >= 0, "WuiGpuSurface received negative proposal dimension: \(resolved)")
        return resolved
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // GpuSurface is stretch-first: without parent constraints it has no intrinsic minimum.
        // This keeps min-size semantics driven by explicit layout constraints (.size/.min_*).
        CGSize(
            width: resolvedProposalDimension(proposal.width),
            height: resolvedProposalDimension(proposal.height)
        )
    }

    // MARK: - Layout

	    #if canImport(UIKit)
	        override func layoutSubviews() {
	            super.layoutSubviews()
	            updateMetalLayerFrame()
	            initializeGpuIfNeeded()
	            updateDisplayLinkState()
	        }

	        override func didMoveToWindow() {
	            super.didMoveToWindow()
	            // Update scale factor when added to window
	            currentScaleFactor = contentScaleFactor
	            updateMetalLayerFrame()
	            initializeGpuIfNeeded()
	            updateDisplayLinkState()
	        }
	    #elseif canImport(AppKit)
	        override func layout() {
	            super.layout()
	            updateMetalLayerFrame()
	            initializeGpuIfNeeded()
	            updateDisplayLinkState()
	        }

        override var isFlipped: Bool { true }

        override var wantsLayer: Bool {
            get { true }
            set {}
        }

	        override func viewDidMoveToWindow() {
	            super.viewDidMoveToWindow()
	            // Update scale factor when added to window
	            currentScaleFactor = window?.backingScaleFactor ?? 1.0
	            updateMetalLayerFrame()
	            initializeGpuIfNeeded()
	            updateWindowObservers()
	            updateDisplayLinkState()
	        }

	        override func viewDidChangeBackingProperties() {
	            super.viewDidChangeBackingProperties()
	            // Handle display change (e.g., moved to different monitor)
	            if let newScale = window?.backingScaleFactor, newScale != currentScaleFactor {
	                currentScaleFactor = newScale
	                updateMetalLayerFrame()
	                initializeGpuIfNeeded()
	                updateDisplayLinkState()
	            }
	        }

	        override func viewDidHide() {
	            super.viewDidHide()
	            updateDisplayLinkState()
	        }

	        override func viewDidUnhide() {
	            super.viewDidUnhide()
	            updateDisplayLinkState()
	        }
	    #endif

    private func updateMetalLayerFrame() {
        guard metalLayer != nil else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        metalLayer.frame = bounds
        metalLayer.contentsScale = currentScaleFactor

        CATransaction.commit()
    }

	    #if canImport(AppKit)
	        private func updateWindowObservers() {
	            if observedWindow === window { return }

	            let center = NotificationCenter.default
	            for token in windowObservers {
	                center.removeObserver(token)
	            }
	            windowObservers.removeAll()
	            observedWindow = window

	            guard let window else { return }

	            windowObservers.append(
	                center.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.updateDisplayLinkState()
                    }
                }
            )
            windowObservers.append(
                center.addObserver(
                    forName: NSWindow.didMiniaturizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.updateDisplayLinkState()
                    }
                }
            )
            windowObservers.append(
                center.addObserver(
                    forName: NSWindow.didDeminiaturizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.updateDisplayLinkState()
                    }
                }
            )
            windowObservers.append(
                center.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.updateDisplayLinkState()
                    }
                }
            )
            windowObservers.append(
                center.addObserver(
                    forName: NSWindow.didResignKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.updateDisplayLinkState()
                    }
                }
            )
        }
    #endif

	    // MARK: - Cleanup

	    @MainActor deinit {
            pictureInPictureHostBridge = nil
	        stopDisplayLink()
	        #if canImport(UIKit)
	            let center = NotificationCenter.default
	            for token in appObservers {
	                center.removeObserver(token)
	            }
	            appObservers.removeAll()
	        #elseif canImport(AppKit)
	            let center = NotificationCenter.default
	            for token in windowObservers {
	                center.removeObserver(token)
	            }
	            windowObservers.removeAll()
	        #endif
	        renderState.shutdown()
	    }
}

// MARK: - UIGestureRecognizerDelegate

#if canImport(UIKit)
extension WuiGpuSurface: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer.view is UIScrollView || otherGestureRecognizer.view is UIScrollView {
            return true
        }

        // Allow pinch and pan gestures to work together
        let isPinch = gestureRecognizer is UIPinchGestureRecognizer
            || otherGestureRecognizer is UIPinchGestureRecognizer
        let isPan = gestureRecognizer is UIPanGestureRecognizer
            || otherGestureRecognizer is UIPanGestureRecognizer

        return isPinch && isPan
    }
}
#endif
