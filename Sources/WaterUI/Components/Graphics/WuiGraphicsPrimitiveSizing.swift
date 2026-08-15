import CoreGraphics

@MainActor
protocol WuiGraphicsPrimitiveSizing {
  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize
}

extension WuiGraphicsPrimitiveSizing {
  /// Graphics leaves are greedy: they fill whatever the layout proposes and
  /// have no size of their own (unproposed axes measure 0). This matches the
  /// hydrolysis renderer's `graphics_dimensions_from_proposal` and SwiftUI's
  /// shape sizing; a nonzero fallback here would invent an intrinsic size
  /// the framework semantic does not have.
  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    CGSize(
      width: proposal.width.map(CGFloat.init) ?? 0,
      height: proposal.height.map(CGFloat.init) ?? 0
    )
  }
}
