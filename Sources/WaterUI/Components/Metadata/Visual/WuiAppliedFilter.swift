// WuiAppliedFilter.swift
// GPU-based filter rendering using wgpu
//
// This component handles Metadata<AppliedFilter> views:
// 1. Captures child view content to a texture
// 2. Sends texture to Rust for GPU filtering
// 3. Displays filtered result
//
// Setup runs on the shared render queue and fully awaits Rust-side initialization.

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

private struct WuiAppliedFilterRenderOutcome: Sendable {
    let success: Bool
    let needsRedraw: Bool
}

/// Thread-safe render state for AppliedFilter.
private final class WuiAppliedFilterRenderState: @unchecked Sendable {
    private var filterState: OpaquePointer?
    private var isInitializing = false
    private var isSetup = false
    private var isActive = true
    private var renderInFlight = false
    private var width: UInt32 = 0
    private var height: UInt32 = 0
    private var preRender: ((OpaquePointer, UInt32, UInt32) -> Bool)?
    private var captureRenderer: CARenderer?
    private var captureQueue: MTLCommandQueue?
    private var captureQueueDevice: MTLDevice?

    private let lock = NSLock()

    func updateSize(width: UInt32, height: UInt32) {
        lock.lock()
        self.width = width
        self.height = height
        lock.unlock()
    }

    /// Initialize filter resources on the shared render queue.
    func initializeIfNeeded(
        filter: UnsafeMutablePointer<WuiAppliedFilter_Struct>,
        layerPtr: UnsafeMutableRawPointer,
        width: UInt32,
        height: UInt32,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        lock.lock()
        if !isActive {
            lock.unlock()
            completion(false)
            return
        }

        self.width = width
        self.height = height

        if filterState != nil && isSetup {
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

        let completionCopy = completion
        let filterAddr = Int(bitPattern: filter)
        let layerAddr = Int(bitPattern: layerPtr)

        WuiSharedRenderQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completionCopy(false) }
                return
            }

            guard let filterPtr = UnsafeMutablePointer<WuiAppliedFilter_Struct>(bitPattern: filterAddr),
                let layerPtr = UnsafeMutableRawPointer(bitPattern: layerAddr)
            else {
                self.lock.lock()
                self.isInitializing = false
                self.lock.unlock()
                DispatchQueue.main.async { completionCopy(false) }
                return
            }

            guard let state = waterui_applied_filter_init(filterPtr, layerPtr, width, height) else {
                self.lock.lock()
                self.isInitializing = false
                self.lock.unlock()
                Logger.waterui.error("[AppliedFilter] Init failed")
                DispatchQueue.main.async { completionCopy(false) }
                return
            }

            self.lock.lock()
            guard self.isActive else {
                self.isInitializing = false
                self.lock.unlock()
                waterui_applied_filter_drop(state)
                DispatchQueue.main.async { completionCopy(false) }
                return
            }
            self.lock.unlock()

            let setupSucceeded = waterui_applied_filter_setup(state)

            self.lock.lock()
            self.isInitializing = false
            let shouldKeepState = self.isActive && setupSucceeded
            if shouldKeepState {
                self.filterState = state
                self.isSetup = true
            } else {
                self.filterState = nil
                self.isSetup = false
            }
            self.lock.unlock()

            if !shouldKeepState {
                Logger.waterui.error("[AppliedFilter] Setup failed")
                waterui_applied_filter_drop(state)
            }

            DispatchQueue.main.async {
                completionCopy(shouldKeepState)
            }
        }
    }

    @discardableResult
    func requestRender(
        prepareOutput: (UInt32, UInt32) -> Void,
        completion: @escaping @Sendable (WuiAppliedFilterRenderOutcome) -> Void
    ) -> Bool {
        lock.lock()
        if !isActive || !isSetup {
            lock.unlock()
            return false
        }

        guard let state = filterState, width > 0, height > 0, !renderInFlight else {
            lock.unlock()
            return false
        }

        renderInFlight = true
        let stateAddr = Int(bitPattern: state)
        let width = self.width
        let height = self.height
        lock.unlock()

        if !waterui_applied_filter_sync_targets(state) {
            lock.lock()
            renderInFlight = false
            lock.unlock()
            return false
        }

        let outputSize = waterui_applied_filter_resolve_output_size(state, width, height)
        prepareOutput(outputSize.width, outputSize.height)

        WuiSharedRenderQueue.async { [weak self] in
            guard let self else { return }

            guard let state = OpaquePointer(bitPattern: stateAddr) else {
                self.lock.lock()
                self.renderInFlight = false
                self.lock.unlock()
                DispatchQueue.main.async {
                    completion(WuiAppliedFilterRenderOutcome(success: false, needsRedraw: false))
                }
                return
            }

            let renderHook: ((OpaquePointer, UInt32, UInt32) -> Bool)?
            self.lock.lock()
            renderHook = self.preRender
            self.lock.unlock()

            if let renderHook, !renderHook(state, width, height) {
                self.lock.lock()
                self.renderInFlight = false
                self.lock.unlock()
                DispatchQueue.main.async {
                    completion(WuiAppliedFilterRenderOutcome(success: false, needsRedraw: true))
                }
                return
            }
            let result = waterui_applied_filter_render(state, width, height)
            let outcome = WuiAppliedFilterRenderOutcome(
                success: result.success,
                needsRedraw: result.needs_redraw
            )
            self.lock.lock()
            self.renderInFlight = false
            self.lock.unlock()
            DispatchQueue.main.async {
                completion(outcome)
            }
        }
        return true
    }

    func pollNeedsRender() -> Bool {
        lock.lock()
        guard isActive, isSetup, !renderInFlight, let state = filterState else {
            lock.unlock()
            return false
        }
        let stateAddr = Int(bitPattern: state)
        lock.unlock()

        guard let state = OpaquePointer(bitPattern: stateAddr) else {
            return false
        }

        return waterui_applied_filter_poll_redraw(state)
    }

    func shutdown() {
        lock.lock()
        isActive = false
        let state = filterState
        filterState = nil
        lock.unlock()

        WuiSharedRenderQueue.barrier {
            if let state { waterui_applied_filter_drop(state) }
        }
    }

    func setPreRender(_ hook: ((OpaquePointer, UInt32, UInt32) -> Bool)?) {
        lock.lock()
        preRender = hook
        lock.unlock()
    }

    func renderNativeLayer(
        _ layer: CALayer,
        targetTexture: MTLTexture,
        width: UInt32,
        height: UInt32
    ) -> MTLCommandBuffer? {
        guard width > 0, height > 0 else { return nil }

        let device = targetTexture.device
        let queue: MTLCommandQueue?
        lock.lock()
        if captureQueue == nil || captureQueueDevice !== device {
            captureQueueDevice = device
            captureQueue = device.makeCommandQueue()
            captureRenderer = nil
        }
        queue = captureQueue
        lock.unlock()

        let renderer: CARenderer
        let colorSpace: CGColorSpace? = {
            switch targetTexture.pixelFormat {
            case .rgba16Float:
                return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            default:
                return CGColorSpace(name: CGColorSpace.sRGB)
            }
        }()

        if let existing = captureRenderer {
            renderer = existing
            renderer.setDestination(targetTexture)
        } else {
            var options: [String: Any] = [
                kCARendererColorSpace as String: colorSpace as Any,
            ]
            if let queue {
                options[kCARendererMetalCommandQueue as String] = queue
            }
            renderer = CARenderer(mtlTexture: targetTexture, options: options)
            captureRenderer = renderer
        }

        renderer.layer = layer
        renderer.bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let now = CACurrentMediaTime()
        renderer.beginFrame(atTime: now, timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        guard let queue, let commandBuffer = queue.makeCommandBuffer() else { return nil }
        commandBuffer.commit()
        // Caller decides where to wait to avoid blocking the main thread.
        return commandBuffer
    }
}

/// GPU filter component for Metadata<AppliedFilter>.
///
/// Captures child view content and applies GPU filters via wgpu.
/// Uses CAMetalLayer for output display.
@MainActor
final class WuiAppliedFilter: PlatformView, WuiComponent, WuiFirstPaintReadyParticipant, @unchecked Sendable {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_applied_filter_id() }

    private let contentView: any WuiComponent
    private let renderState: WuiAppliedFilterRenderState
    private var ffiFilter: WuiAppliedFilter_Struct

    /// Output metal layer for filtered content
    private var outputLayer: CAMetalLayer!
    /// Whether GPU resources are initialized
    private var isGpuInitialized = false

    /// Content scale factor
    private var currentScaleFactor: CGFloat = 1.0
    private var captureCommandQueue: MTLCommandQueue?
    private var activeGpuSurfaces: [ObjectIdentifier: WuiGpuSurface] = [:]
    private var overlayTexture: MTLTexture?
    private var overlaySize: CGSize = .zero
    private var compositePipeline: MTLRenderPipelineState?
    private var compositePipelineFormat: MTLPixelFormat = .invalid
    private var compositeSampler: MTLSamplerState?
    private var gpuSurfaceTextures: [ObjectIdentifier: MTLTexture] = [:]
    private var gpuSurfaceTextureSizes: [ObjectIdentifier: CGSize] = [:]
    private var gpuSurfaceHasContent: Set<ObjectIdentifier> = []
    private var needsRender = false
    private var filteredOutputRevealed = false
    private var configuredDynamicRangeMode: WuiDynamicRangeMode?
    private var outputDrawablePixelSize: CGSize = .zero

    /// Display link for render sync
    #if canImport(UIKit)
        private var displayLink: CADisplayLink?
    #elseif canImport(AppKit)
        private var displayLink: CADisplayLink?
    #endif

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_applied_filter(anyview)
        self.ffiFilter = metadata

        // Resolve child view
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)
        self.renderState = WuiAppliedFilterRenderState()

        super.init(frame: .zero)

        #if canImport(AppKit)
            wantsLayer = true
        #endif

        setupOutputLayer()
        setupContentView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupOutputLayer() {
        outputLayer = CAMetalLayer()

        guard let device = MTLCreateSystemDefaultDevice() else {
            Logger.waterui.error("[AppliedFilter] Failed to create Metal device")
            return
        }

        outputLayer.device = device
        outputLayer.framebufferOnly = true
        outputLayer.maximumDrawableCount = 3
        outputLayer.isOpaque = false
        #if canImport(UIKit)
            outputLayer.backgroundColor = UIColor.clear.cgColor
        #elseif canImport(AppKit)
            outputLayer.backgroundColor = NSColor.clear.cgColor
        #endif
        outputLayer.zPosition = 1
        outputLayer.pixelFormat = .rgba16Float
        outputLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        outputLayer.wantsExtendedDynamicRangeContent = true
        outputLayer.isHidden = true

        #if canImport(UIKit)
            layer.addSublayer(outputLayer)
        #elseif canImport(AppKit)
            guard let layer = self.layer else {
                fatalError("AppliedFilter host view must be layer-backed before output layer setup")
            }
            layer.backgroundColor = NSColor.clear.cgColor
            layer.addSublayer(outputLayer)
        #endif

        configureOutputDynamicRange()
    }

    private func setupContentView() {
        contentView.translatesAutoresizingMaskIntoConstraints = true
        // Keep content in the view tree for layout/capture; output layer overlays it.
        addSubview(contentView)
        contentView.isHidden = false
        setCaptureContentLayerHidden(true)
        outputLayer.removeFromSuperlayer()
        #if canImport(UIKit)
            layer.addSublayer(outputLayer)
        #elseif canImport(AppKit)
            guard let layer = self.layer else {
                fatalError("AppliedFilter host view must be layer-backed before content setup")
            }
            layer.addSublayer(outputLayer)
        #endif

        configureOutputDynamicRange()

        setupCapturePipeline()
    }

    private func configureOutputDynamicRange() {
        let mode = resolveDynamicRange(for: self)
        applyDynamicRange(mode, to: self)
        applyDynamicRange(mode, to: outputLayer)

        guard configuredDynamicRangeMode != mode else { return }
        guard !isGpuInitialized else { return }

        if mode == .high {
            outputLayer.pixelFormat = .rgba16Float
            outputLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            outputLayer.wantsExtendedDynamicRangeContent = true
        } else {
            outputLayer.pixelFormat = .bgra8Unorm_srgb
            outputLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            outputLayer.wantsExtendedDynamicRangeContent = false
        }

        configuredDynamicRangeMode = mode
    }

    private func setCaptureContentLayerHidden(_ hidden: Bool) {
        #if canImport(AppKit)
            ensureLayerBacked(contentView)
        #endif
        let layer = contentView.layer
        #if canImport(AppKit)
        guard let layer else {
            fatalError("AppliedFilter capture content view must be layer-backed before visibility updates")
        }
        #endif
        guard layer.isHidden != hidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = hidden
        CATransaction.commit()
    }

    private func setupCapturePipeline() {
        renderState.setPreRender { [weak self] state, width, height in
            guard let self else { return false }
            var captureTexture: MTLTexture?
            var overlayTexture: MTLTexture?
            var snapshots: [GpuSurfaceSnapshot] = []
            var device: MTLDevice?
            var nativeCaptureFence: MTLCommandBuffer?
            var capturePrepared = false

            let mainBlock = {
                self.withVisibleContentForCapture {
                    self.prepareCaptureView(self.contentView)
                    guard let outputDevice = self.outputLayer.device else { return }
                    device = outputDevice
                    guard let texture = self.prepareRustCaptureTexture(
                        state: state,
                        width: width,
                        height: height
                    ) else {
                        return
                    }
                    captureTexture = texture

                    snapshots = self.collectGpuSurfaceSnapshots(captureTexture: texture)
                    self.updateExternalGpuSurfaces(snapshots)
                    if snapshots.isEmpty {
                        guard let layer = self.resolveCaptureLayer(from: self.contentView) else { return }
                        nativeCaptureFence = self.renderState.renderNativeLayer(
                            layer,
                            targetTexture: texture,
                            width: width,
                            height: height
                        )
                        nativeCaptureFence?.waitUntilCompleted()
                    } else {
                        guard let overlay = self.ensureOverlayTexture(
                            device: outputDevice,
                            pixelFormat: texture.pixelFormat,
                            width: width,
                            height: height
                        ) else {
                            return
                        }
                        overlayTexture = overlay
                        self.withHiddenGpuSurfaces {
                            guard let layer = self.resolveCaptureLayer(from: self.contentView) else { return }
                            nativeCaptureFence = self.renderState.renderNativeLayer(
                                layer,
                                targetTexture: overlay,
                                width: width,
                                height: height
                            )
                            nativeCaptureFence?.waitUntilCompleted()
                        }
                    }
                    capturePrepared = true
                }
            }

            self.runOnMainThreadSynchronously(mainBlock)

            guard capturePrepared, let device, let captureTexture, let nativeCaptureFence else {
                return false
            }

            if !snapshots.isEmpty {
                guard self.renderGpuSurfaces(
                    snapshots,
                    into: captureTexture,
                    overlayTexture: overlayTexture,
                    device: device
                ) else {
                    return false
                }
            }
            return true
        }
    }

    private func runOnMainThreadSynchronously(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
            return
        }
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.main.async {
            work()
            group.leave()
        }
        group.wait()
    }

    private func withVisibleContentForCapture(_ work: () -> Void) {
        #if canImport(AppKit)
            ensureLayerBacked(contentView)
        #endif
        let layer = contentView.layer
        #if canImport(AppKit)
        guard let layer else {
            fatalError("AppliedFilter capture content view must be layer-backed before snapshot capture")
        }
        #endif
        let wasHidden = layer.isHidden
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = false
        CATransaction.commit()

        work()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = wasHidden
        CATransaction.commit()
    }

    private func prepareCaptureView(_ view: PlatformView) {
        #if canImport(AppKit)
            ensureLayerBacked(view)
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            view.layer?.setNeedsLayout()
            view.layer?.layoutIfNeeded()
            view.needsDisplay = true
            view.displayIfNeeded()
        #elseif canImport(UIKit)
            view.setNeedsLayout()
            view.layoutIfNeeded()
        #endif
    }

    #if canImport(AppKit)
    private func ensureLayerBacked(_ view: PlatformView) {
        if view.layer == nil {
            view.wantsLayer = true
        }
        for subview in view.subviews {
            ensureLayerBacked(subview)
        }
    }
    #endif

    private func resolveCaptureLayer(from view: PlatformView) -> CALayer? {
        guard let component = view as? WuiComponent else {
            return view.layer
        }

        if isMetadataComponent(component) {
            if let contentSubview = view.subviews.first(where: { $0 is WuiComponent }) {
                return resolveCaptureLayer(from: contentSubview)
            }
        }

        #if canImport(AppKit)
            if view.layer == nil {
                view.wantsLayer = true
            }
        #endif

        #if canImport(UIKit)
            return view.layer
        #elseif canImport(AppKit)
            return view.layer
        #endif
    }

    private struct GpuSurfaceSnapshot {
        let surface: WuiGpuSurface
        let origin: MTLOrigin
        let size: MTLSize
    }

    private func collectGpuSurfaceSnapshots(captureTexture: MTLTexture) -> [GpuSurfaceSnapshot] {
        var snapshots: [GpuSurfaceSnapshot] = []
        collectGpuSurfaceSnapshots(
            from: contentView,
            into: &snapshots,
            captureWidth: captureTexture.width,
            captureHeight: captureTexture.height
        )
        return snapshots
    }

    private func updateExternalGpuSurfaces(_ snapshots: [GpuSurfaceSnapshot]) {
        var next: [ObjectIdentifier: WuiGpuSurface] = [:]
        next.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            let id = ObjectIdentifier(snapshot.surface)
            next[id] = snapshot.surface
        }

        for (id, surface) in activeGpuSurfaces where next[id] == nil {
            surface.endExternalRendering()
        }
        for (id, surface) in next where activeGpuSurfaces[id] == nil {
            surface.beginExternalRendering()
        }

        activeGpuSurfaces = next
    }

    private func collectGpuSurfaceSnapshots(
        from view: PlatformView,
        into snapshots: inout [GpuSurfaceSnapshot],
        captureWidth: Int,
        captureHeight: Int
    ) {
        if let surface = view as? WuiGpuSurface {
            let rect = surface.convert(surface.bounds, to: contentView)
            let scale = currentScaleFactor
            let originX = Int((rect.origin.x * scale).rounded(.down))
            let originY = Int((rect.origin.y * scale).rounded(.down))
            let width = Int((rect.size.width * scale).rounded(.up))
            let height = Int((rect.size.height * scale).rounded(.up))

            let clampedOriginX = max(0, originX)
            let clampedOriginY = max(0, originY)
            let maxWidth = min(width, captureWidth - clampedOriginX)
            let maxHeight = min(height, captureHeight - clampedOriginY)

            if maxWidth > 0, maxHeight > 0 {
                snapshots.append(GpuSurfaceSnapshot(
                    surface: surface,
                    origin: MTLOrigin(x: clampedOriginX, y: clampedOriginY, z: 0),
                    size: MTLSize(width: maxWidth, height: maxHeight, depth: 1)
                ))
            }
            return
        }

        for subview in view.subviews {
            if subview is WuiComponent {
                collectGpuSurfaceSnapshots(
                    from: subview,
                    into: &snapshots,
                    captureWidth: captureWidth,
                    captureHeight: captureHeight
                )
            }
        }
    }

    private func withHiddenGpuSurfaces(_ work: () -> Void) {
        var surfaces: [WuiGpuSurface] = []
        collectGpuSurfaces(in: contentView, into: &surfaces)
        if surfaces.isEmpty {
            work()
            return
        }

        for surface in surfaces {
            surface.beginCaptureSuppression()
        }
        work()
        for surface in surfaces {
            surface.endCaptureSuppression()
        }
    }

    private func collectGpuSurfaces(in view: PlatformView, into surfaces: inout [WuiGpuSurface]) {
        if let surface = view as? WuiGpuSurface {
            surfaces.append(surface)
            return
        }

        for subview in view.subviews {
            if subview is WuiComponent {
                collectGpuSurfaces(in: subview, into: &surfaces)
            }
        }
    }

    private func containsGpuSurface(in view: PlatformView) -> Bool {
        if view is WuiGpuSurface {
            return true
        }

        return view.subviews.contains { subview in
            subview is WuiComponent && containsGpuSurface(in: subview)
        }
    }

    private func prepareRustCaptureTexture(
        state: OpaquePointer,
        width: UInt32,
        height: UInt32
    ) -> MTLTexture? {
        _ = waterui_applied_filter_prepare_capture(state, width, height)
        guard let rawTexture = waterui_applied_filter_get_capture_metal_texture(state) else {
            Logger.waterui.error("[AppliedFilter] Rust capture texture is unavailable")
            return nil
        }
        let object = Unmanaged<AnyObject>.fromOpaque(rawTexture).takeUnretainedValue()
        guard let texture = object as? MTLTexture else {
            fatalError("AppliedFilter capture texture must bridge to MTLTexture")
        }
        return texture
    }

    private func ensureOverlayTexture(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        width: UInt32,
        height: UInt32
    ) -> MTLTexture? {
        if let texture = overlayTexture,
           overlaySize.width == CGFloat(width),
           overlaySize.height == CGFloat(height),
           texture.pixelFormat == pixelFormat
        {
            return texture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: Int(width),
            height: Int(height),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared

        let texture = device.makeTexture(descriptor: descriptor)
        overlayTexture = texture
        overlaySize = CGSize(width: Int(width), height: Int(height))
        return texture
    }

    private func ensureSurfaceTexture(
        for surface: WuiGpuSurface,
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        width: UInt32,
        height: UInt32
    ) -> MTLTexture? {
        let key = ObjectIdentifier(surface)
        let size = CGSize(width: Int(width), height: Int(height))
        if let texture = gpuSurfaceTextures[key],
           gpuSurfaceTextureSizes[key] == size
        {
            return texture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: Int(width),
            height: Int(height),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)
        gpuSurfaceTextures[key] = texture
        gpuSurfaceTextureSizes[key] = size
        gpuSurfaceHasContent.remove(key)
        return texture
    }

    private func ensureCommandQueue(device: MTLDevice) -> MTLCommandQueue? {
        if let queue = captureCommandQueue, queue.device === device {
            return queue
        }
        let queue = device.makeCommandQueue()
        captureCommandQueue = queue
        return queue
    }

    private func renderGpuSurfaces(
        _ snapshots: [GpuSurfaceSnapshot],
        into captureTexture: MTLTexture,
        overlayTexture: MTLTexture?,
        device: MTLDevice
    ) -> Bool {
        var rendered: [(snapshot: GpuSurfaceSnapshot, texture: MTLTexture)] = []
        rendered.reserveCapacity(snapshots.count)
        var hasMissingFirstFrame = false

        for snapshot in snapshots {
            let width = UInt32(snapshot.size.width)
            let height = UInt32(snapshot.size.height)
            guard let surfaceTexture = ensureSurfaceTexture(
                for: snapshot.surface,
                device: device,
                pixelFormat: captureTexture.pixelFormat,
                width: width,
                height: height
            ) else { continue }

            let renderedOk = snapshot.surface.renderToMetalTexture(
                texture: surfaceTexture,
                width: width,
                height: height
            )
            if renderedOk {
                gpuSurfaceHasContent.insert(ObjectIdentifier(snapshot.surface))
                rendered.append((snapshot, surfaceTexture))
            } else if gpuSurfaceHasContent.contains(ObjectIdentifier(snapshot.surface)) {
                rendered.append((snapshot, surfaceTexture))
            } else {
                hasMissingFirstFrame = true
            }
        }

        // Never present partially populated GPU overlays. Wait until every snapshot has either
        // a fresh frame or a cached previous frame to keep visual consistency.
        if hasMissingFirstFrame {
            return false
        }

        guard let queue = ensureCommandQueue(device: device),
              let commandBuffer = queue.makeCommandBuffer()
        else {
            return false
        }

        encodeClear(captureTexture, commandBuffer: commandBuffer)

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            for entry in rendered {
                blit.copy(
                    from: entry.texture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: .init(x: 0, y: 0, z: 0),
                    sourceSize: entry.snapshot.size,
                    to: captureTexture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: entry.snapshot.origin
                )
            }
            blit.endEncoding()
        }

        if let overlayTexture {
            encodeCompositeOverlay(
                overlayTexture,
                onto: captureTexture,
                commandBuffer: commandBuffer,
                device: device
            )
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return true
    }

    private func encodeClear(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.endEncoding()
        }
    }

    private func encodeCompositeOverlay(
        _ overlayTexture: MTLTexture,
        onto captureTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        device: MTLDevice
    ) {
        guard let pipeline = ensureCompositePipeline(device: device, format: captureTexture.pixelFormat),
              let sampler = ensureCompositeSampler(device: device)
        else {
            return
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = captureTexture
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(overlayTexture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func ensureCompositePipeline(
        device: MTLDevice,
        format: MTLPixelFormat
    ) -> MTLRenderPipelineState? {
        if let pipeline = compositePipeline, compositePipelineFormat == format {
            return pipeline
        }

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex VertexOut vertex_main(uint vertexID [[vertex_id]]) {
            float2 pos[3] = { {-1.0, -1.0}, {3.0, -1.0}, {-1.0, 3.0} };
            float2 uv[3] = { {0.0, 0.0}, {2.0, 0.0}, {0.0, 2.0} };
            VertexOut out;
            out.position = float4(pos[vertexID], 0.0, 1.0);
            out.uv = uv[vertexID];
            return out;
        }

        fragment float4 fragment_main(
            VertexOut in [[stage_in]],
            texture2d<float> overlayTexture [[texture(0)]],
            sampler overlaySampler [[sampler(0)]]
        ) {
            return overlayTexture.sample(overlaySampler, in.uv);
        }
        """

        do {
            let library = try device.makeLibrary(source: source, options: nil)
            guard let vertex = library.makeFunction(name: "vertex_main"),
                  let fragment = library.makeFunction(name: "fragment_main")
            else {
                return nil
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = format
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            compositePipeline = pipeline
            compositePipelineFormat = format
            return pipeline
        } catch {
            Logger.waterui.error("[AppliedFilter] Failed to create composite pipeline")
            return nil
        }
    }

    private func ensureCompositeSampler(device: MTLDevice) -> MTLSamplerState? {
        if let sampler = compositeSampler {
            return sampler
        }

        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        let sampler = device.makeSamplerState(descriptor: descriptor)
        compositeSampler = sampler
        return sampler
    }

    // MARK: - GPU Initialization

    private func initializeGpuIfNeeded() {
        guard bounds.width > 0 && bounds.height > 0 else { return }

        configureOutputDynamicRange()

        #if canImport(UIKit)
            currentScaleFactor = contentScaleFactor
        #elseif canImport(AppKit)
            currentScaleFactor =
                window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
        #endif

        let width = UInt32(bounds.width * currentScaleFactor)
        let height = UInt32(bounds.height * currentScaleFactor)

        renderState.updateSize(width: width, height: height)
        if outputDrawablePixelSize == .zero {
            outputDrawablePixelSize = CGSize(width: Int(width), height: Int(height))
        }
        updateOutputLayerFrame()

        guard !isGpuInitialized else { return }

        let layerPtr = Unmanaged.passUnretained(outputLayer).toOpaque()

        withUnsafeMutablePointer(to: &ffiFilter) { filterPtr in
            renderState.initializeIfNeeded(
                filter: filterPtr,
                layerPtr: layerPtr,
                width: width,
                height: height
            ) { [weak self] success in
                guard let self else { return }
                // We're already on main thread (completion dispatches to main)
                // but we need to inform Swift we're on MainActor
                MainActor.assumeIsolated {
                    guard success else {
                        Logger.waterui.error("[AppliedFilter] GPU initialization failed")
                        return
                    }
                    self.isGpuInitialized = true
                    self.requestRenderIfNeeded()
                }
            }
        }
    }

    // MARK: - Display Link

    #if canImport(UIKit)
        private func startDisplayLink() {
            guard displayLink == nil else { return }
            displayLink = CADisplayLink(target: self, selector: #selector(render))

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

    private func requestRenderIfNeeded() {
        needsRender = true
        scheduleFrameIfNeeded()
    }

    private func scheduleFrameIfNeeded() {
        guard isGpuInitialized else { return }
        guard window != nil else {
            stopDisplayLink()
            return
        }
        startDisplayLink()
    }

    private func renderFrame() {
        if !needsRender {
            needsRender = renderState.pollNeedsRender()
        }
        guard needsRender else {
            return
        }
        needsRender = false

        let started = renderState.requestRender(
            prepareOutput: { [weak self] outputWidth, outputHeight in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.setOutputDrawableSize(width: outputWidth, height: outputHeight)
                }
            },
            completion: { [weak self] result in
                guard let self else { return }
                MainActor.assumeIsolated {
                    if result.success {
                        self.revealFilteredOutputNow()
                    } else {
                        Logger.waterui.error("[AppliedFilter] Render failed")
                    }
                    if result.needsRedraw {
                        self.needsRender = true
                    }
                    self.scheduleFrameIfNeeded()
                }
            }
        )
        if !started {
            needsRender = true
        }
        scheduleFrameIfNeeded()
    }

    private func requestReadyFrame(completion: @escaping @Sendable (Bool) -> Void) {
        let started = renderState.requestRender(
            prepareOutput: { [weak self] outputWidth, outputHeight in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.setOutputDrawableSize(width: outputWidth, height: outputHeight)
                }
            },
            completion: { [weak self] outcome in
                MainActor.assumeIsolated {
                    if outcome.success, let self {
                        self.revealFilteredOutputNow()
                    }
                    completion(outcome.success)
                }
            }
        )
        if !started {
            completion(false)
        }
    }

    fileprivate func revealFilteredOutputNow() {
        guard !filteredOutputRevealed else { return }
        filteredOutputRevealed = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outputLayer.isHidden = false
        CATransaction.commit()
    }

    func prepareForReady() {
        #if canImport(UIKit)
            setNeedsLayout()
            layoutIfNeeded()
        #elseif canImport(AppKit)
            needsLayout = true
            layoutSubtreeIfNeeded()
        #endif
        initializeGpuIfNeeded()
        requestRenderIfNeeded()
    }

    func waitForReady() async -> Bool {
        await withCheckedContinuation { continuation in
            requestReadyFrame { ok in
                continuation.resume(returning: ok)
            }
        }
    }

    func waitForReadySynchronously() -> Bool {
        let waitState = WuiSynchronousReadyWaitState()

        requestReadyFrame { ok in
            MainActor.assumeIsolated {
                waitState.result = ok
            }
        }

        while waitState.result == nil {
            _ = RunLoop.current.run(mode: .default, before: .distantFuture)
        }

        return waitState.result ?? false
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

    func layoutPriority() -> Int32 {
        contentView.layoutPriority()
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        contentView.sizeThatFits(proposal)
    }

    // MARK: - Layout

    #if canImport(UIKit)
        override func layoutSubviews() {
            super.layoutSubviews()
            contentView.frame = bounds
            contentView.setNeedsLayout()
            contentView.layoutIfNeeded()
            updateOutputLayerFrame()
            initializeGpuIfNeeded()
            requestRenderIfNeeded()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                currentScaleFactor = contentScaleFactor
                updateOutputLayerFrame()
                initializeGpuIfNeeded()
                requestRenderIfNeeded()
            } else {
                stopDisplayLink()
            }
        }
    #elseif canImport(AppKit)
        override var isFlipped: Bool { true }

        override var wantsLayer: Bool {
            get { super.wantsLayer }
            set { super.wantsLayer = newValue }
        }

        override func layout() {
            super.layout()
            contentView.frame = bounds
            contentView.needsLayout = true
            contentView.layoutSubtreeIfNeeded()
            updateOutputLayerFrame()
            initializeGpuIfNeeded()
            requestRenderIfNeeded()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                currentScaleFactor = window?.backingScaleFactor ?? 1.0
                updateOutputLayerFrame()
                initializeGpuIfNeeded()
                requestRenderIfNeeded()
            } else {
                stopDisplayLink()
            }
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            if let newScale = window?.backingScaleFactor, newScale != currentScaleFactor {
                currentScaleFactor = newScale
                updateOutputLayerFrame()
                initializeGpuIfNeeded()
                requestRenderIfNeeded()
            }
        }
    #endif

    private func updateOutputLayerFrame() {
        guard outputLayer != nil else { return }

        configureOutputDynamicRange()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        outputLayer.frame = bounds
        outputLayer.contentsScale = currentScaleFactor

        let drawableSize: CGSize
        if outputDrawablePixelSize.width > 0 && outputDrawablePixelSize.height > 0 {
            drawableSize = outputDrawablePixelSize
        } else {
            drawableSize = CGSize(
                width: bounds.width * currentScaleFactor,
                height: bounds.height * currentScaleFactor
            )
        }

        if drawableSize.width > 0 && drawableSize.height > 0 {
            outputLayer.drawableSize = drawableSize
        }

        CATransaction.commit()
    }

    private func setOutputDrawableSize(width: UInt32, height: UInt32) {
        outputDrawablePixelSize = CGSize(width: Int(width), height: Int(height))
        updateOutputLayerFrame()
    }

    // MARK: - Cleanup

    @MainActor deinit {
        for (_, surface) in activeGpuSurfaces {
            surface.endExternalRendering()
        }
        activeGpuSurfaces.removeAll()
        stopDisplayLink()
        renderState.shutdown()
    }
}

// Type alias for the FFI struct
private typealias WuiAppliedFilter_Struct = CWaterUI.WuiAppliedFilter
