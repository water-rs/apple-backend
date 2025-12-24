// WuiSystemIcon.swift
// SystemIcon component - renders SF Symbols on Apple platforms
//
// # Layout Behavior
// SystemIcon is content-sized, using the intrinsic size of the symbol.
// The default size is based on system font body size.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: .none (content-sized, does not expand)
// // - sizeThatFits: Returns intrinsic size based on symbol
// // - Priority: 0 (default)

import CWaterUI
import os

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private let logger = Logger(subsystem: "dev.waterui", category: "WuiSystemIcon")

@MainActor
final class WuiSystemIcon: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_system_icon_id() }

    #if canImport(UIKit)
    private let imageView = UIImageView()
    #elseif canImport(AppKit)
    private let imageView = NSImageView()
    #endif

    private let iconName: String

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiIcon: CWaterUI.WuiSystemIcon = waterui_force_as_system_icon(anyview)
        let name = WuiStr(ffiIcon.name).toString()
        self.init(name: name)
    }

    // MARK: - Designated Init

    init(name: String) {
        self.iconName = name
        super.init(frame: .zero)
        configureImageView()
        loadSymbol()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    private func configureImageView() {
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        #if canImport(UIKit)
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .label
        #elseif canImport(AppKit)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        // Use template mode so it respects tint/appearance
        imageView.contentTintColor = .labelColor
        #endif
    }

    private func loadSymbol() {
        #if canImport(UIKit)
        if let image = UIImage(systemName: iconName) {
            imageView.image = image
        } else {
            logger.warning("SF Symbol not found: \(self.iconName, privacy: .public)")
            // Use a placeholder symbol
            imageView.image = UIImage(systemName: "questionmark.square.dashed")
        }
        #elseif canImport(AppKit)
        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
            imageView.image = image
        } else {
            logger.warning("SF Symbol not found: \(self.iconName, privacy: .public)")
            // Use a placeholder symbol
            imageView.image = NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: nil)
        }
        #endif
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // Default size for SF Symbols is roughly 17pt (body text size)
        // We use intrinsic content size if available
        #if canImport(UIKit)
        let intrinsic = imageView.intrinsicContentSize
        if intrinsic.width > 0 && intrinsic.height > 0 {
            return intrinsic
        }
        // Fallback to a reasonable default
        return CGSize(width: 17, height: 17)
        #elseif canImport(AppKit)
        if let image = imageView.image {
            return image.size
        }
        // Fallback to a reasonable default
        return CGSize(width: 17, height: 17)
        #endif
    }

    #if canImport(AppKit)
    override var isFlipped: Bool { true }
    #endif
}
