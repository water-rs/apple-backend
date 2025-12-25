// WuiDisplayLinkManager.swift
// Manages a shared DisplayLink for all GpuSurfaces to reduce thread overhead.

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
    import CoreVideo
#endif

import OSLog

@MainActor
final class WuiDisplayLinkManager {
    static let shared = WuiDisplayLinkManager()

    /// Weak references to observers
    private var observers = NSHashTable<AnyObject>.weakObjects()

    #if canImport(UIKit)
        private var displayLink: CADisplayLink?
    #elseif canImport(AppKit)
        private var displayLink: CVDisplayLink?
        private var displayLinkUserInfo: UnsafeMutableRawPointer?
    #endif

    private init() {}

    func addObserver(_ observer: WuiDisplayLinkObserver) {
        let wasEmpty = observers.allObjects.isEmpty
        observers.add(observer)

        if wasEmpty {
            startDisplayLink()
        }
    }

    func removeObserver(_ observer: WuiDisplayLinkObserver) {
        observers.remove(observer)
        if observers.allObjects.isEmpty {
            stopDisplayLink()
        }
    }

    // MARK: - Display Link Logic

    #if canImport(UIKit)
        private func startDisplayLink() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(render))
            
            // Request up to 120fps on ProMotion
            if #available(iOS 15.0, tvOS 15.0, *) {
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 60,
                    maximum: 120,
                    preferred: 120
                )
            }
            
            link.add(to: .main, forMode: .common)
            displayLink = link
            Logger.waterui.debug("[DisplayLinkManager] Started global display link")
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
            Logger.waterui.debug("[DisplayLinkManager] Stopped global display link")
        }

        @objc private func render() {
            for case let observer as WuiDisplayLinkObserver in observers.allObjects {
                observer.onFrame()
            }
        }

    #elseif canImport(AppKit)
        private func startDisplayLink() {
            guard displayLink == nil else { return }

            var link: CVDisplayLink?
            let status = CVDisplayLinkCreateWithActiveCGDisplays(&link)
            guard status == kCVReturnSuccess, let link else { return }

            displayLink = link
            
            // Pass self as unretained because we are a singleton (effectively static info)
            let userInfo = Unmanaged.passUnretained(self).toOpaque()
            displayLinkUserInfo = userInfo

            CVDisplayLinkSetOutputCallback(
                link,
                { _, _, _, _, _, userInfo -> CVReturn in
                    guard let userInfo else { return kCVReturnError }
                    let manager = Unmanaged<WuiDisplayLinkManager>.fromOpaque(userInfo).takeUnretainedValue()
                    
                    // Dispatch to main thread to interact with observers (which are MainActor)
                    DispatchQueue.main.async {
                        manager.tickRestrictedToMain()
                    }
                    
                    return kCVReturnSuccess
                },
                userInfo
            )

            CVDisplayLinkStart(link)
            Logger.waterui.debug("[DisplayLinkManager] Started global display link")
        }
        
        /// Tick method that runs on main thread
        private func tickRestrictedToMain() {
            // NSHashTable enumeration is safe on MainActor if modified on MainActor
            for case let observer as WuiDisplayLinkObserver in observers.allObjects {
                observer.onFrame()
            }
        }

        private func stopDisplayLink() {
            if let link = displayLink {
                CVDisplayLinkStop(link)
                displayLink = nil
            }
            displayLinkUserInfo = nil
            Logger.waterui.debug("[DisplayLinkManager] Stopped global display link")
        }
    #endif
}

@MainActor
protocol WuiDisplayLinkObserver: AnyObject {
    func onFrame()
}
