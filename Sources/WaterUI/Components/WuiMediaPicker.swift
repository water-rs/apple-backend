// WuiMediaPicker.swift
// Media picker component that presents native photo/video picker
//
// # Platform Support
// - iOS 14+: Uses PHPickerViewController
// - macOS: Not fully supported (uses NSOpenPanel as fallback)
//
// # Features
// - Filters for photos, videos, live photos
// - Single and multiple selection
// - Reactive selection updates

import CWaterUI
import PhotosUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Media Loading Registry

/// Thread-safe registry for pending media selections.
/// Maps selection IDs to either PHPickerResult (iOS) or file URL (macOS).
final class MediaRegistry: @unchecked Sendable {
    static let shared = MediaRegistry()

    private var nextId: UInt32 = 1
    private let lock = NSLock()

    #if canImport(UIKit)
    private var pendingResults: [UInt32: PHPickerResult] = [:]
    #endif
    private var pendingURLs: [UInt32: URL] = [:]

    private init() {}

    #if canImport(UIKit)
    /// Register a PHPickerResult and return its ID.
    func register(_ result: PHPickerResult) -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        let id = nextId
        nextId += 1
        pendingResults[id] = result
        return id
    }
    #endif

    /// Register a file URL and return its ID.
    func register(_ url: URL) -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        let id = nextId
        nextId += 1
        pendingURLs[id] = url
        return id
    }

    #if canImport(UIKit)
    /// Get and remove a PHPickerResult by ID.
    func takePHPickerResult(_ id: UInt32) -> PHPickerResult? {
        lock.lock()
        defer { lock.unlock() }
        return pendingResults.removeValue(forKey: id)
    }
    #endif

    /// Get and remove a URL by ID.
    func takeURL(_ id: UInt32) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return pendingURLs.removeValue(forKey: id)
    }
}

// MARK: - waterui_load_media Implementation

/// Media type constants matching Rust's MediaLoadResult.media_type
private enum MediaType: UInt8 {
    case image = 0
    case video = 1
    case livePhoto = 2
}

/// Called by Rust when Selected::load() is invoked.
/// Loads the media and calls the callback with the file URL.
@_cdecl("waterui_load_media")
public func waterui_load_media(id: UInt32, callback: MediaLoadCallback) {
    #if canImport(UIKit)
    // Try PHPickerResult first (iOS)
    if let result = MediaRegistry.shared.takePHPickerResult(id) {
        loadFromPHPickerResult(result, callback: callback)
        return
    }
    #endif

    // Try direct URL (macOS or fallback)
    if let url = MediaRegistry.shared.takeURL(id) {
        completeWithURL(url, videoURL: nil, mediaType: .image, callback: callback)
        return
    }

    fatalError("waterui_load_media: no media found for id \(id)")
}

#if canImport(UIKit)
/// Load media from a PHPickerResult.
private func loadFromPHPickerResult(_ result: PHPickerResult, callback: MediaLoadCallback) {
    let itemProvider = result.itemProvider

    // Determine media type and load accordingly
    if itemProvider.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier) {
        loadLivePhoto(from: itemProvider, callback: callback)
    } else if itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
        loadVideo(from: itemProvider, callback: callback)
    } else if itemProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        loadImage(from: itemProvider, callback: callback)
    } else {
        fatalError("waterui_load_media: unsupported media type")
    }
}

private func loadImage(from itemProvider: NSItemProvider, callback: MediaLoadCallback) {
    itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
        guard let sourceURL = url else {
            fatalError("waterui_load_media: failed to load image: \(error?.localizedDescription ?? "unknown")")
        }

        // Copy to temp location (file representation is temporary)
        let tempURL = copyToTempDirectory(sourceURL, extension: sourceURL.pathExtension)
        completeWithURL(tempURL, videoURL: nil, mediaType: .image, callback: callback)
    }
}

private func loadVideo(from itemProvider: NSItemProvider, callback: MediaLoadCallback) {
    itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
        guard let sourceURL = url else {
            fatalError("waterui_load_media: failed to load video: \(error?.localizedDescription ?? "unknown")")
        }

        let tempURL = copyToTempDirectory(sourceURL, extension: sourceURL.pathExtension)
        completeWithURL(tempURL, videoURL: nil, mediaType: .video, callback: callback)
    }
}

private func loadLivePhoto(from itemProvider: NSItemProvider, callback: MediaLoadCallback) {
    // Load Live Photo - need to extract both image and video components
    // PHLivePhoto bundle contains paired HEIC image and MOV video

    let group = DispatchGroup()
    var imageURL: URL?
    var videoURL: URL?
    var loadError: Error?

    // Load image component
    group.enter()
    itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.heic.identifier) { url, error in
        defer { group.leave() }
        if let url = url {
            imageURL = copyToTempDirectory(url, extension: "heic")
        } else {
            // Fallback to JPEG
            itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier) { url, error in
                if let url = url {
                    imageURL = copyToTempDirectory(url, extension: "jpg")
                } else {
                    loadError = error
                }
            }
        }
    }

    // Load video component
    group.enter()
    itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.quickTimeMovie.identifier) { url, error in
        defer { group.leave() }
        if let url = url {
            videoURL = copyToTempDirectory(url, extension: "mov")
        } else {
            loadError = error
        }
    }

    group.notify(queue: .global()) {
        guard let imageURL = imageURL, let videoURL = videoURL else {
            fatalError("waterui_load_media: failed to load Live Photo components: \(loadError?.localizedDescription ?? "unknown")")
        }
        completeWithURL(imageURL, videoURL: videoURL, mediaType: .livePhoto, callback: callback)
    }
}
#endif

/// Copy a file to a temporary directory.
private func copyToTempDirectory(_ sourceURL: URL, extension ext: String) -> URL {
    let tempDir = FileManager.default.temporaryDirectory
    let fileName = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
    let destURL = tempDir.appendingPathComponent(fileName)

    do {
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        return destURL
    } catch {
        fatalError("waterui_load_media: failed to copy file: \(error.localizedDescription)")
    }
}

/// Complete the callback with file URLs.
private func completeWithURL(_ url: URL, videoURL: URL?, mediaType: MediaType, callback: MediaLoadCallback) {
    let urlString = url.absoluteString
    let videoURLString = videoURL?.absoluteString ?? ""

    urlString.withCString { urlCString in
        videoURLString.withCString { videoCString in
            let result = MediaLoadResult(
                url_ptr: UnsafePointer<UInt8>(OpaquePointer(urlCString)),
                url_len: UInt(urlString.utf8.count),
                video_url_ptr: videoURL != nil ? UnsafePointer<UInt8>(OpaquePointer(videoCString)) : nil,
                video_url_len: UInt(videoURLString.utf8.count),
                media_type: mediaType.rawValue
            )
            callback.call(callback.data, result)
        }
    }
}

// MARK: - WuiMediaPicker Component

@MainActor
final class WuiMediaPicker: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_media_picker_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let filterType: CWaterUI.WuiMediaFilterType
    private var onSelection: CWaterUI.WuiFn_WuiSelected

    #if canImport(UIKit)
    private weak var presentingViewController: UIViewController?
    private let button: UIButton
    #elseif canImport(AppKit)
    private let button: NSButton
    #endif

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiPicker: CWaterUI.WuiMediaPicker = waterui_force_as_media_picker(anyview)
        self.init(
            filter: ffiPicker.filter,
            onSelection: ffiPicker.on_selection
        )
    }

    // MARK: - Designated Init

    init(filter: CWaterUI.WuiMediaFilterType, onSelection: CWaterUI.WuiFn_WuiSelected) {
        self.filterType = filter
        self.onSelection = onSelection

        #if canImport(UIKit)
        self.button = UIButton(type: .system)
        super.init(frame: .zero)

        button.setTitle("Select Media", for: .normal)
        button.addTarget(self, action: #selector(presentPicker), for: .touchUpInside)
        addSubview(button)
        #elseif canImport(AppKit)
        self.button = NSButton(title: "Select Media", target: nil, action: nil)
        super.init(frame: .zero)

        button.target = self
        button.action = #selector(presentPicker)
        addSubview(button)
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        #if canImport(UIKit)
        let intrinsic = button.intrinsicContentSize
        #elseif canImport(AppKit)
        let intrinsic = button.intrinsicContentSize
        #endif

        let width = proposal.width.map { CGFloat($0) } ?? intrinsic.width
        let height = proposal.height.map { CGFloat($0) } ?? intrinsic.height
        return CGSize(width: max(width, intrinsic.width), height: max(height, intrinsic.height))
    }

    // MARK: - Layout

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        button.frame = bounds
    }
    #elseif canImport(AppKit)
    override func layout() {
        super.layout()
        button.frame = bounds
    }

    override var isFlipped: Bool { true }

    override var wantsLayer: Bool {
        get { true }
        set { }
    }
    #endif

    // MARK: - Picker Presentation

    @objc
    private func presentPicker() {
        #if canImport(UIKit)
        presentIOSPicker()
        #elseif canImport(AppKit)
        presentMacOSPicker()
        #endif
    }

    #if canImport(UIKit)
    private func presentIOSPicker() {
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 1

        // Configure filter based on type
        switch filterType {
        case WuiMediaFilterType_Image:
            configuration.filter = .images
        case WuiMediaFilterType_Video:
            configuration.filter = .videos
        case WuiMediaFilterType_LivePhoto:
            configuration.filter = .livePhotos
        case WuiMediaFilterType_All:
            configuration.filter = .any(of: [.images, .videos, .livePhotos])
        default:
            configuration.filter = .any(of: [.images, .videos])
        }

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self

        // Find the presenting view controller
        if let viewController = findViewController() {
            viewController.present(picker, animated: true)
        }
    }

    private func findViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let nextResponder = responder?.next {
            if let vc = nextResponder as? UIViewController {
                return vc
            }
            responder = nextResponder
        }
        return nil
    }
    #endif

    #if canImport(AppKit)
    private func presentMacOSPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        // Configure allowed content types based on filter
        var contentTypes: [UTType] = []
        switch filterType {
        case WuiMediaFilterType_Image:
            contentTypes = [.image]
        case WuiMediaFilterType_Video:
            contentTypes = [.movie, .video]
        case WuiMediaFilterType_LivePhoto:
            contentTypes = [.livePhoto]
        case WuiMediaFilterType_All:
            contentTypes = [.image, .movie, .video]
        default:
            contentTypes = [.image, .movie]
        }
        panel.allowedContentTypes = contentTypes

        panel.begin { [weak self] response in
            guard let self = self else { return }
            if response == .OK, let url = panel.url {
                // Register the URL and get a unique ID
                let id = MediaRegistry.shared.register(url)
                let selected = CWaterUI.WuiSelected(id: id)
                self.onSelection.call(self.onSelection.data, selected)
            }
        }
    }
    #endif
}

#if canImport(UIKit)
extension WuiMediaPicker: PHPickerViewControllerDelegate {
    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        // Register the result immediately on the current thread (nonisolated context)
        // PHPickerResult is not Sendable, so we must process it before crossing actor boundaries
        let selectedId: UInt32? = results.first.map { MediaRegistry.shared.register($0) }

        Task { @MainActor in
            picker.dismiss(animated: true)

            if let id = selectedId {
                let selected = CWaterUI.WuiSelected(id: id)
                onSelection.call(onSelection.data, selected)
            }
        }
    }
}
#endif
