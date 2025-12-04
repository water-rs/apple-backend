// Platform.swift
// Platform-specific type aliases for cross-platform code sharing

import CWaterUI

#if canImport(UIKit)
import UIKit

public typealias PlatformView = UIView
public typealias PlatformStackView = UIStackView
public typealias PlatformSwitch = UISwitch
public typealias PlatformSlider = UISlider
public typealias PlatformTextField = UITextField
public typealias PlatformButton = UIButton
public typealias PlatformProgressView = UIProgressView
public typealias PlatformActivityIndicator = UIActivityIndicatorView
public typealias PlatformStepper = UIStepper
public typealias PlatformScrollView = UIScrollView
public typealias PlatformLabel = UILabel
public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
public typealias PlatformImage = UIImage
public typealias PlatformLayoutPriority = UILayoutPriority

#elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

public typealias PlatformView = NSView
public typealias PlatformStackView = NSStackView
public typealias PlatformSwitch = NSSwitch
public typealias PlatformSlider = NSSlider
public typealias PlatformTextField = NSTextField
public typealias PlatformButton = NSButton
public typealias PlatformProgressView = NSProgressIndicator
public typealias PlatformActivityIndicator = NSProgressIndicator
public typealias PlatformStepper = NSStepper
public typealias PlatformScrollView = NSScrollView
public typealias PlatformLabel = NSTextField
public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
public typealias PlatformImage = NSImage
public typealias PlatformLayoutPriority = NSLayoutConstraint.Priority

#endif

// MARK: - Layout Invalidation

extension PlatformView {
    /// Invalidates layout for this view and all ancestor views.
    /// Use when content size changes and the entire hierarchy needs re-layout.
    func invalidateLayoutHierarchy() {
        #if canImport(UIKit)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        var parent = superview
        while let p = parent {
            p.invalidateIntrinsicContentSize()
            p.setNeedsLayout()
            parent = p.superview
        }
        #elseif canImport(AppKit)
        invalidateIntrinsicContentSize()
        needsLayout = true
        var parent = superview
        while let p = parent {
            p.invalidateIntrinsicContentSize()
            p.needsLayout = true
            parent = p.superview
        }
        #endif
    }
}
