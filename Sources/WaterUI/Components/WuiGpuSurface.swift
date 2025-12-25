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
import Metal
import OSLog
import QuartzCore

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
    import CoreVideo
#endif

private final class WuiGpuSurfaceRenderState: @unchecked Sendable {
    private var ffiSurface: CWaterUI.WuiGpuSurface
    private var gpuState: OpaquePointer?
    private var isInitializing = false
    private var isActive = true
    private var renderInFlight = false
    private var width: UInt32 = 0
    private var height: UInt32 = 0

    private let lock = NSLock()
    private let renderQueue = DispatchQueue(
        label: "waterui.gpu-surface.render",
        qos: .userInteractive
    )

    init(ffiSurface: CWaterUI.WuiGpuSurface) {
        self.ffiSurface = ffiSurface
    }

    func updateSize(width: UInt32, height: UInt32) {
        lock.lock()
        self.width = width
        self.height = height
        lock.unlock()
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

        renderQueue.async { [weak self] in
            guard let self else { return }

            let state: OpaquePointer? = withUnsafeMutablePointer(to: &self.ffiSurface) {
                surfacePtr in
                waterui_gpu_surface_init(surfacePtr, layerPtr, width, height)
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
                completion(success)
            }
        }
    }

    func requestRender() {
        lock.lock()
        if !isActive {
            lock.unlock()
            return
        }

        guard let state = gpuState, width > 0, height > 0, !renderInFlight else {
            lock.unlock()
            return
        }

        renderInFlight = true
        let width = self.width
        let height = self.height
        lock.unlock()

        renderQueue.async { [weak self] in
            guard let self else { return }
            _ = waterui_gpu_surface_render(state, width, height)
            self.lock.lock()
            self.renderInFlight = false
            self.lock.unlock()
        }
    }

    /// Get current state and initialization status (thread-safe).
    private func getStateInfo() -> (state: OpaquePointer?, isInitializing: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (gpuState, isInitializing)
    }

    /// Await GPU setup completion and first frame render.
    /// This is used to ensure all GpuSurfaces are ready before showing the window.
    func awaitReady() async {
        // Wait for state to be available
        var state: OpaquePointer?
        while true {
            let info = getStateInfo()
            state = info.state

            if state != nil {
                break
            }
            if !info.isInitializing {
                // Not initialized and not initializing - nothing to wait for
                return
            }
            // Poll every 10ms while initializing
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        guard let state else { return }

        // Call await_ready on render queue with callback
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            renderQueue.async {
                // Create a context to pass through the callback
                let context = Unmanaged.passRetained(continuation as AnyObject).toOpaque()

                waterui_gpu_surface_await_ready(
                    state,
                    { userData in
                        guard let userData else { return }
                        let cont = Unmanaged<AnyObject>.fromOpaque(userData).takeRetainedValue()
                        if let continuation = cont as? CheckedContinuation<Void, Never> {
                            continuation.resume()
                        }
                    },
                    context
                )
            }
        }
    }

    func shutdown() {
        lock.lock()
        isActive = false
        let state = gpuState
        gpuState = nil
        lock.unlock()

        renderQueue.sync {
            if let state { waterui_gpu_surface_drop(state) }
        }
    }
}

/// High-performance GPU rendering surface using wgpu.
/// Uses CAMetalLayer with CADisplayLink for 120fps rendering.
@MainActor
final class WuiGpuSurface: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_gpu_surface_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let renderState: WuiGpuSurfaceRenderState

    /// The CAMetalLayer for GPU rendering
    private var metalLayer: CAMetalLayer!

    /// Display link for frame sync (120fps capable)
    #if canImport(UIKit)
        private var displayLink: CADisplayLink?
    #elseif canImport(AppKit)
        private var displayLink: CVDisplayLink?
        private var displayLinkUserInfo: UnsafeMutableRawPointer?
    #endif

    /// Whether we've initialized the GPU resources
    private var isGpuInitialized = false

    /// Content scale factor for high-DPI displays
    private var currentScaleFactor: CGFloat = 1.0

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        let ffiSurface = waterui_force_as_gpu_surface(anyview)
        self.init(stretchAxis: stretchAxis, ffiSurface: ffiSurface)
    }

    // MARK: - Designated Init

    init(stretchAxis: WuiStretchAxis, ffiSurface: CWaterUI.WuiGpuSurface) {
        self.stretchAxis = stretchAxis
        self.renderState = WuiGpuSurfaceRenderState(ffiSurface: ffiSurface)

        super.init(frame: .zero)

        setupMetalLayer()
    }

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
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3  // Triple buffering for smooth 120fps
        metalLayer.isOpaque = false  // Allow transparency for compositing with background
        metalLayer.backgroundColor = CGColor.clear  // Ensure no black background

        // Configure HDR support if available
        configureHDR()

        #if canImport(UIKit)
            // iOS/tvOS: Add metal layer as sublayer
            layer.addSublayer(metalLayer)
        #elseif canImport(AppKit)
            // macOS: Need to set wantsLayer and add sublayer
            wantsLayer = true
            if self.layer == nil {
                self.layer = CALayer()
            }
            self.layer?.backgroundColor = CGColor.clear
            self.layer?.addSublayer(metalLayer)
        #endif
    }

    /// Configure the metal layer for HDR rendering
    private func configureHDR() {
        // Use Rgba16Float for HDR support (must match Rust side)
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        metalLayer.wantsExtendedDynamicRangeContent = true
    }

    // MARK: - GPU Initialization

    private func initializeGpuIfNeeded() {
        guard bounds.width > 0 && bounds.height > 0 else { return }

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
            self.startDisplayLink()
            // Trigger immediate first render to avoid empty frame on window open
            self.renderFrame()
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

            var link: CVDisplayLink?
            let status = CVDisplayLinkCreateWithActiveCGDisplays(&link)
            guard status == kCVReturnSuccess, let link else { return }

            displayLink = link

            let userInfo = Unmanaged.passRetained(renderState).toOpaque()
            displayLinkUserInfo = userInfo

            CVDisplayLinkSetOutputCallback(
                link,
                { _, _, _, _, _, userInfo -> CVReturn in
                    guard let userInfo else { return kCVReturnError }
                    let state = Unmanaged<WuiGpuSurfaceRenderState>.fromOpaque(userInfo)
                        .takeUnretainedValue()
                    state.requestRender()
                    return kCVReturnSuccess
                },
                userInfo
            )

            CVDisplayLinkStart(link)
        }

        private func stopDisplayLink() {
            if let link = displayLink {
                CVDisplayLinkStop(link)
                displayLink = nil
            }

            if let userInfo = displayLinkUserInfo {
                Unmanaged<WuiGpuSurfaceRenderState>.fromOpaque(userInfo).release()
                displayLinkUserInfo = nil
            }
        }
    #endif

    private func renderFrame() {
        renderState.requestRender()
    }

    // MARK: - Async Ready

    /// Wait for GPU setup and first frame to complete.
    /// Call this before showing the window to prevent flicker.
    nonisolated func waitForReady() async {
        await renderState.awaitReady()
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // GpuSurface stretches to fill available space
        let defaultSize: CGFloat = 100

        let width = proposal.width.map { CGFloat($0) } ?? defaultSize
        let height = proposal.height.map { CGFloat($0) } ?? defaultSize

        return CGSize(width: width, height: height)
    }

    // MARK: - Layout

    #if canImport(UIKit)
        override func layoutSubviews() {
            super.layoutSubviews()
            updateMetalLayerFrame()
            initializeGpuIfNeeded()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                // Update scale factor when added to window
                currentScaleFactor = contentScaleFactor
                updateMetalLayerFrame()
                initializeGpuIfNeeded()
            }
        }
    #elseif canImport(AppKit)
        override func layout() {
            super.layout()
            updateMetalLayerFrame()
            initializeGpuIfNeeded()
        }

        override var isFlipped: Bool { true }

        override var wantsLayer: Bool {
            get { true }
            set {}
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                // Update scale factor when added to window
                currentScaleFactor = window?.backingScaleFactor ?? 1.0
                updateMetalLayerFrame()
                initializeGpuIfNeeded()
            }
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            // Handle display change (e.g., moved to different monitor)
            if let newScale = window?.backingScaleFactor, newScale != currentScaleFactor {
                currentScaleFactor = newScale
                updateMetalLayerFrame()
                initializeGpuIfNeeded()
            }
        }
    #endif

    private func updateMetalLayerFrame() {
        guard metalLayer != nil else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        metalLayer.frame = bounds
        metalLayer.contentsScale = currentScaleFactor

        let width = bounds.width * currentScaleFactor
        let height = bounds.height * currentScaleFactor
        if width > 0 && height > 0 {
            metalLayer.drawableSize = CGSize(width: width, height: height)
        }

        CATransaction.commit()
    }

    // MARK: - Cleanup

    @MainActor deinit {
        stopDisplayLink()
        renderState.shutdown()
    }
}
