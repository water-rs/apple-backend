@_exported import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

// MARK: - Proposal and Layout Types

public struct WuiProposalSize: Equatable {
  public var width: Float?
  public var height: Float?

  public init(width: Float? = nil, height: Float? = nil) {
    self.width = width
    self.height = height
  }

  public init(size: CGSize) {
    self.width = size.width.isNaN ? nil : Float(size.width)
    self.height = size.height.isNaN ? nil : Float(size.height)
  }
}

struct WuiSize {
  var width: Float
  var height: Float

  init(_ size: CGSize) {
    self.width = Float(size.width)
    self.height = Float(size.height)
  }

  var cgSize: CGSize {
    CGSize(width: CGFloat(width), height: CGFloat(height))
  }
}

public struct WuiHorizontalGuide {
  var alignment: CWaterUI.WuiHorizontalAlignment
  var value: Float

  init(_ raw: CWaterUI.WuiHorizontalGuide) {
    self.alignment = raw.alignment
    self.value = raw.value
  }
}

public struct WuiVerticalGuide {
  var alignment: CWaterUI.WuiVerticalAlignment
  var value: Float

  init(_ raw: CWaterUI.WuiVerticalGuide) {
    self.alignment = raw.alignment
    self.value = raw.value
  }
}

public struct WuiViewDimensions {
  var size: WuiSize
  var horizontalGuides: [WuiHorizontalGuide]
  var verticalGuides: [WuiVerticalGuide]

  init(
    size: CGSize,
    horizontalGuides: [WuiHorizontalGuide] = [],
    verticalGuides: [WuiVerticalGuide] = []
  ) {
    self.size = WuiSize(size)
    self.horizontalGuides = horizontalGuides
    self.verticalGuides = verticalGuides
  }
}
