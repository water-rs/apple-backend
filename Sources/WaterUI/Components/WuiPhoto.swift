// WuiPhoto.swift
// Photo component that displays remote images with placeholders
//
// # Layout Behavior
// Photo component displays an image from a URL with an optional placeholder view
// while loading. Uses platform-native image views (UIImageView/NSImageView).
//
// # Event Handling
// Emits Loaded event when image successfully loads
// Emits Error event if image fails to load

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiPhoto: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_photo_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    #if canImport(UIKit)
    private let imageView: UIImageView
    #elseif canImport(AppKit)
    private let imageView: NSImageView
    #endif

    private var placeholderView: (any WuiComponent)?
    private var onEvent: CWaterUI.WuiFn_WuiPhotoEvent
    private let sourceURL: URL
    private var loadTask: Task<Void, Never>?

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiPhoto: CWaterUI.WuiPhoto = waterui_force_as_photo(anyview)

        let sourceStr = WuiStr(ffiPhoto.source)
        let sourceURLString = sourceStr.toString()
        let onEvent = ffiPhoto.on_event

        // Placeholder view if provided
        var placeholderComponent: (any WuiComponent)?
        if let placeholderPtr = ffiPhoto.placeholder {
            placeholderComponent = WuiAnyView.resolve(anyview: placeholderPtr, env: env)
        }

        self.init(sourceURL: sourceURLString, placeholder: placeholderComponent, onEvent: onEvent, env: env)
    }

    private let env: WuiEnvironment

    // MARK: - Designated Init

    init(sourceURL: String, placeholder: (any WuiComponent)?, onEvent: CWaterUI.WuiFn_WuiPhotoEvent, env: WuiEnvironment) {
        self.sourceURL = URL(string: sourceURL) ?? URL(fileURLWithPath: "")
        self.placeholderView = placeholder
        self.onEvent = onEvent
        self.env = env

        #if canImport(UIKit)
        self.imageView = UIImageView()
        super.init(frame: .zero)
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        #elseif canImport(AppKit)
        self.imageView = NSImageView()
        super.init(frame: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
        #endif

        // Add placeholder if provided (WuiComponent IS the view - it inherits from PlatformView)
        if let placeholder = placeholderView {
            addSubview(placeholder)
        }

        // Start loading image
        loadImage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // Use proposed size or default to a reasonable image size
        let defaultSize: CGFloat = 200
        let width = proposal.width.map { CGFloat($0) } ?? defaultSize
        let height = proposal.height.map { CGFloat($0) } ?? defaultSize
        return CGSize(width: width, height: height)
    }

    // MARK: - Layout

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        placeholderView?.frame = bounds
    }
    #elseif canImport(AppKit)
    override func layout() {
        super.layout()
        imageView.frame = bounds
        placeholderView?.frame = bounds
    }

    override var isFlipped: Bool { true }

    override var wantsLayer: Bool {
        get { true }
        set { }
    }
    #endif

    // MARK: - Image Loading

    private func loadImage() {
        loadTask = Task {
            do {
                // Download image data
                let (data, _) = try await URLSession.shared.data(from: sourceURL)

                // Check if task was cancelled
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    #if canImport(UIKit)
                    if let image = UIImage(data: data) {
                        imageView.image = image
                        hidePlaceholder()
                        emitLoadedEvent()
                    } else {
                        emitErrorEvent("Failed to decode image")
                    }
                    #elseif canImport(AppKit)
                    if let image = NSImage(data: data) {
                        imageView.image = image
                        hidePlaceholder()
                        emitLoadedEvent()
                    } else {
                        emitErrorEvent("Failed to decode image")
                    }
                    #endif
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    emitErrorEvent(error.localizedDescription)
                }
            }
        }
    }

    private func hidePlaceholder() {
        placeholderView?.isHidden = true
    }

    private func emitLoadedEvent() {
        let event = CWaterUI.WuiPhotoEvent(
            event_type: CWaterUI.WuiPhotoEventType_Loaded,
            error_message: WuiStr(string: "").intoInner()
        )
        onEvent.call(onEvent.data, event)
    }

    private func emitErrorEvent(_ message: String) {
        let event = CWaterUI.WuiPhotoEvent(
            event_type: CWaterUI.WuiPhotoEventType_Error,
            error_message: WuiStr(string: message).intoInner()
        )
        onEvent.call(onEvent.data, event)
    }

    @MainActor deinit {
        loadTask?.cancel()
    }
}
