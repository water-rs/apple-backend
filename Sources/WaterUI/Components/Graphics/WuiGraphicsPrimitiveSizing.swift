import CoreGraphics

@MainActor
protocol WuiGraphicsPrimitiveSizing {
  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize
}

extension WuiGraphicsPrimitiveSizing {
  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    let intrinsicDimension: CGFloat = 10
    return CGSize(
      width: proposal.width.map(CGFloat.init) ?? intrinsicDimension,
      height: proposal.height.map(CGFloat.init) ?? intrinsicDimension
    )
  }
}
