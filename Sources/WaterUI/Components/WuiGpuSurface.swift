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
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// High-performance GPU rendering surface using wgpu.
/// Uses CAMetalLayer with CADisplayLink for 120fps rendering.
@MainActor
final class WuiGpuSurface: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_gpu_surface_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    /// The FFI GpuSurface data (contains renderer pointer)
    private var ffiSurface: CWaterUI.WuiGpuSurface

    /// The CAMetalLayer for GPU rendering
    private var metalLayer: CAMetalLayer!

    /// Opaque state from waterui_gpu_surface_init (owns wgpu resources)
    private var gpuState: OpaquePointer?

    /// Display link for frame sync (120fps capable)
    #if canImport(UIKit)
    private var displayLink: CADisplayLink?
    #elseif canImport(AppKit)
    private var displayLink: CVDisplayLink?
    private var displayLinkSource: DispatchSourceUserDataAdd?
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
        self.ffiSurface = ffiSurface

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
            print("[WuiGpuSurface] Failed to create Metal device")
            return
        }

        metalLayer.device = device
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3  // Triple buffering for smooth 120fps

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
        self.layer?.addSublayer(metalLayer)
        #endif
    }

    /// Configure the metal layer for HDR rendering when available
    private func configureHDR() {
        // Use extended sRGB for HDR content (wide color gamut)
        // This enables HDR on displays that support it
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, *) {
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            metalLayer.pixelFormat = .rgba16Float  // HDR-capable format
            metalLayer.wantsExtendedDynamicRangeContent = true
        } else {
            // Fallback to standard sRGB
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            metalLayer.pixelFormat = .bgra8Unorm
        }
    }

    // MARK: - GPU Initialization

    private func initializeGpuIfNeeded() {
        guard !isGpuInitialized else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }

        #if canImport(UIKit)
        currentScaleFactor = contentScaleFactor
        #elseif canImport(AppKit)
        currentScaleFactor = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
        #endif

        let width = UInt32(bounds.width * currentScaleFactor)
        let height = UInt32(bounds.height * currentScaleFactor)

        // Update metal layer frame and drawable size
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        metalLayer.contentsScale = currentScaleFactor

        // Get pointer to metal layer for wgpu surface creation
        let layerPtr = Unmanaged.passUnretained(metalLayer).toOpaque()

        // Initialize wgpu resources via FFI
        gpuState = withUnsafeMutablePointer(to: &ffiSurface) { surfacePtr in
            waterui_gpu_surface_init(surfacePtr, layerPtr, width, height)
        }

        if gpuState != nil {
            isGpuInitialized = true
            startDisplayLink()
        } else {
            print("[WuiGpuSurface] Failed to initialize GPU resources")
        }
    }

    // MARK: - Display Link

    #if canImport(UIKit)
    private func startDisplayLink() {
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
        // Create a dispatch source for thread-safe callbacks
        displayLinkSource = DispatchSource.makeUserDataAddSource(queue: .main)
        displayLinkSource?.setEventHandler { [weak self] in
            self?.renderFrame()
        }
        displayLinkSource?.resume()

        // Create CVDisplayLink
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)

        guard let displayLink = link else {
            print("[WuiGpuSurface] Failed to create CVDisplayLink")
            return
        }

        self.displayLink = displayLink

        // Set callback
        let source = displayLinkSource
        CVDisplayLinkSetOutputCallback(displayLink, { _, _, _, _, _, userInfo -> CVReturn in
            let source = Unmanaged<DispatchSourceUserDataAdd>.fromOpaque(userInfo!).takeUnretainedValue()
            source.add(data: 1)
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(source!).toOpaque())

        CVDisplayLinkStart(displayLink)
    }

    private func stopDisplayLink() {
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
        }
        displayLink = nil
        displayLinkSource?.cancel()
        displayLinkSource = nil
    }
    #endif

    private func renderFrame() {
        guard let state = gpuState else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }

        let width = UInt32(bounds.width * currentScaleFactor)
        let height = UInt32(bounds.height * currentScaleFactor)

        // Call Rust to render the frame
        // This handles resize internally and calls user's render() callback
        _ = waterui_gpu_surface_render(state, width, height)
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
        set { }
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
        if let state = gpuState {
            waterui_gpu_surface_drop(state)
        }
    }
}
