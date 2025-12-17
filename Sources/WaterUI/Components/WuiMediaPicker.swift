// WuiMediaPicker.swift
// Media picker manager service that presents native photo/video picker
//
// # Platform Support
// - iOS 14+: Uses PHPickerViewController
// - macOS: Uses NSOpenPanel
//
// # Features
// - Filters for photos, videos, live photos
// - Single selection
// - Unified manager for presenting picker and loading media

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
/// Entries are kept after retrieval to allow multiple loads of the same selection.
final class MediaRegistry: @unchecked Sendable {
    static let shared = MediaRegistry()

    private var nextId: UInt32 = 1
    private let lock = NSLock()

    #if canImport(UIKit)
    private var pendingResults: [UInt32: PHPickerResult] = [:]
    /// Cache of loaded URLs from PHPickerResults (for repeated loads)
    private var loadedURLs: [UInt32: (url: URL, videoURL: URL?, mediaType: UInt8)] = [:]
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
    /// Get a PHPickerResult by ID (does not remove).
    func getPHPickerResult(_ id: UInt32) -> PHPickerResult? {
        lock.lock()
        defer { lock.unlock() }
        return pendingResults[id]
    }

    /// Cache a loaded result for future loads.
    func cacheLoadedResult(_ id: UInt32, url: URL, videoURL: URL?, mediaType: UInt8) {
        lock.lock()
        defer { lock.unlock() }
        loadedURLs[id] = (url, videoURL, mediaType)
    }

    /// Get a cached loaded result.
    func getCachedResult(_ id: UInt32) -> (url: URL, videoURL: URL?, mediaType: UInt8)? {
        lock.lock()
        defer { lock.unlock() }
        return loadedURLs[id]
    }
    #endif

    /// Get a URL by ID (does not remove).
    func getURL(_ id: UInt32) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return pendingURLs[id]
    }
}

// MARK: - Media Loader Implementation

/// Media type constants matching Rust's MediaLoadResult.media_type
private enum MediaType: UInt8 {
    case image = 0
    case video = 1
    case livePhoto = 2
}

/// C-compatible function pointer for loading media.
/// Called by Rust when Selected::load() is invoked.
private let loadMediaImpl: @convention(c) (UInt32, MediaLoadCallback) -> Void = { id, callback in
    loadMedia(id: id, callback: callback)
}

/// C-compatible present function
private let presentImpl: @convention(c) (WuiMediaFilterType, MediaPickerPresentCallback) -> Void = { filter, callback in
    // Capture callback components
    // These are C function pointers, safe to send across isolation boundaries
    nonisolated(unsafe) let callbackData = callback.data
    guard let callbackFn = callback.call else { return }
    nonisolated(unsafe) let capturedFn = callbackFn

    Task { @MainActor in
        MediaPickerManagerImpl.shared.present(filter: filter) { selected in
            capturedFn(callbackData, selected)
        }
    }
}

/// Installs the MediaPickerManager into the environment.
/// Call this during WaterUI initialization to enable MediaPicker functionality.
public func installMediaPickerManager(env: OpaquePointer?) {
    waterui_env_install_media_picker_manager(env, presentImpl, loadMediaImpl)
}

/// Loads the media and calls the callback with the file URL.
private func loadMedia(id: UInt32, callback: MediaLoadCallback) {
    #if canImport(UIKit)
    // Check cached result first (for repeated loads)
    if let cached = MediaRegistry.shared.getCachedResult(id) {
        completeWithURL(cached.url, videoURL: cached.videoURL, mediaType: MediaType(rawValue: cached.mediaType) ?? .image, callback: callback)
        return
    }

    // Try PHPickerResult (iOS)
    if let result = MediaRegistry.shared.getPHPickerResult(id) {
        loadFromPHPickerResult(result, id: id, callback: callback)
        return
    }
    #endif

    // Try direct URL (macOS or fallback)
    if let url = MediaRegistry.shared.getURL(id) {
        let mediaType: MediaType
        if let type = UTType(filenameExtension: url.pathExtension) {
            if type.conforms(to: .movie) || type.conforms(to: .video) {
                mediaType = .video
            } else if type.conforms(to: .image) {
                mediaType = .image
            } else {
                mediaType = .image
            }
        } else {
            mediaType = .image
        }
        completeWithURL(url, videoURL: nil, mediaType: mediaType, callback: callback)
        return
    }

    fatalError("waterui_load_media: no media found for id \(id)")
}

#if canImport(UIKit)
/// Load media from a PHPickerResult.
private func loadFromPHPickerResult(_ result: PHPickerResult, id: UInt32, callback: MediaLoadCallback) {
    let itemProvider = result.itemProvider

    // Determine media type and load accordingly
    if itemProvider.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier) {
        loadLivePhoto(from: itemProvider, id: id, callback: callback)
    } else if itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
        loadVideo(from: itemProvider, id: id, callback: callback)
    } else if itemProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        loadImage(from: itemProvider, id: id, callback: callback)
    } else {
        fatalError("waterui_load_media: unsupported media type")
    }
}

private func loadImage(from itemProvider: NSItemProvider, id: UInt32, callback: MediaLoadCallback) {
    itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
        guard let sourceURL = url else {
            fatalError("waterui_load_media: failed to load image: \(error?.localizedDescription ?? "unknown")")
        }

        // Copy to temp location (file representation is temporary)
        let tempURL = copyToTempDirectory(sourceURL, extension: sourceURL.pathExtension)
        // Cache for future loads
        MediaRegistry.shared.cacheLoadedResult(id, url: tempURL, videoURL: nil, mediaType: MediaType.image.rawValue)
        completeWithURL(tempURL, videoURL: nil, mediaType: .image, callback: callback)
    }
}

private func loadVideo(from itemProvider: NSItemProvider, id: UInt32, callback: MediaLoadCallback) {
    itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
        guard let sourceURL = url else {
            fatalError("waterui_load_media: failed to load video: \(error?.localizedDescription ?? "unknown")")
        }

        let tempURL = copyToTempDirectory(sourceURL, extension: sourceURL.pathExtension)
        // Cache for future loads
        MediaRegistry.shared.cacheLoadedResult(id, url: tempURL, videoURL: nil, mediaType: MediaType.video.rawValue)
        completeWithURL(tempURL, videoURL: nil, mediaType: .video, callback: callback)
    }
}

private func loadLivePhoto(from itemProvider: NSItemProvider, id: UInt32, callback: MediaLoadCallback) {
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
        // Cache for future loads
        MediaRegistry.shared.cacheLoadedResult(id, url: imageURL, videoURL: videoURL, mediaType: MediaType.livePhoto.rawValue)
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

// MARK: - MediaPickerManager Service

/// Swift implementation of MediaPickerManager
@MainActor
final class MediaPickerManagerImpl {
    static let shared = MediaPickerManagerImpl()

    private var pendingCallback: ((SelectedId) -> Void)?

    private init() {}

    /// Present the media picker with the given filter
    func present(filter: WuiMediaFilterType, callback: @escaping (SelectedId) -> Void) {
        self.pendingCallback = callback

        #if canImport(UIKit)
        presentIOSPicker(filter: filter)
        #elseif canImport(AppKit)
        presentMacOSPicker(filter: filter)
        #endif
    }

    #if canImport(UIKit)
    private func presentIOSPicker(filter: WuiMediaFilterType) {
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 1

        // Configure filter based on type
        switch filter {
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

        // Find root view controller to present picker
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }),
           let rootVC = window.rootViewController {
            var presentingVC = rootVC
            while let presented = presentingVC.presentedViewController {
                presentingVC = presented
            }
            presentingVC.present(picker, animated: true)
        }
    }
    #endif

    #if canImport(AppKit)
    private func presentMacOSPicker(filter: WuiMediaFilterType) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        // Configure allowed content types based on filter
        var contentTypes: [UTType] = []
        switch filter {
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
                if let callback = self.pendingCallback {
                    callback(id)
                    self.pendingCallback = nil
                }
            }
        }
    }
    #endif
}

#if canImport(UIKit)
extension MediaPickerManagerImpl: PHPickerViewControllerDelegate {
    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        // Register the result immediately on the current thread (nonisolated context)
        // PHPickerResult is not Sendable, so we must process it before crossing actor boundaries
        let selectedId: UInt32? = results.first.map { MediaRegistry.shared.register($0) }

        Task { @MainActor in
            picker.dismiss(animated: true)

            if let id = selectedId, let callback = self.pendingCallback {
                callback(id)
                self.pendingCallback = nil
            }
        }
    }
}
#endif
