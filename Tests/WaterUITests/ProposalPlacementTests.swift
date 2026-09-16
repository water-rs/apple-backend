import CWaterUI
import CoreGraphics
import Testing

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@testable import WaterUI

/// A content view recording every proposal it is offered, standing in for the
/// resolved component a transparent wrapper or label-hosting control owns.
@MainActor
private final class RecordingContentView: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { CWaterUI.WuiTypeId() }

  var placedProposals: [WaterUI.WuiProposalSize] = []
  var measuredProposals: [WaterUI.WuiProposalSize] = []
  var intrinsic = CGSize(width: 7, height: 5)

  init() {
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    fatalError("RecordingContentView is not resolved from FFI")
  }

  func sizeThatFits(_ proposal: WaterUI.WuiProposalSize) -> CGSize {
    measuredProposals.append(proposal)
    return intrinsic
  }

  func setPlacementProposal(_ proposal: WaterUI.WuiProposalSize) {
    placedProposals.append(proposal)
  }
}

@MainActor
struct ProposalPlacementTests {
  // MARK: - Placement packet

  /// Equal bounds can carry different selected proposals — the contract
  /// exists because a frame does not determine the offer that produced it.
  /// Decoding must preserve both fields independently.
  @Test func placementDecodesFrameAndProposalIndependently() {
    let frame = CWaterUI.WuiRect(
      origin: CWaterUI.WuiPoint(x: 10, y: 20),
      size: CWaterUI.WuiSize(width: 100, height: 44)
    )
    let first = WaterUI.WuiSubviewPlacement(
      CWaterUI.WuiSubviewPlacement(
        frame: frame,
        proposal: WaterUI.WuiProposalSize(width: 300, height: nil).toCStruct()
      ))
    let second = WaterUI.WuiSubviewPlacement(
      CWaterUI.WuiSubviewPlacement(
        frame: frame,
        proposal: WaterUI.WuiProposalSize(width: 100, height: 44).toCStruct()
      ))

    #expect(first.frame == CGRect(x: 10, y: 20, width: 100, height: 44))
    #expect(second.frame == first.frame)
    #expect(first.proposal.width == 300)
    #expect(first.proposal.height == nil)
    #expect(second.proposal == WaterUI.WuiProposalSize(width: 100, height: 44))
    #expect(first.proposal != second.proposal)
  }

  /// The C ABI encodes an unspecified axis as NaN; the Swift side decodes it
  /// as `nil` and encodes `nil` back as NaN. The round trip is what keeps a
  /// nil scroll axis or a lazy child main axis unspecified end to end.
  @Test func proposalNilAxesRoundTripThroughNaN() {
    let unspecified = WaterUI.WuiProposalSize(width: nil, height: nil)
    let rawUnspecified = unspecified.toCStruct()
    #expect(rawUnspecified.width.isNaN)
    #expect(rawUnspecified.height.isNaN)
    #expect(WaterUI.WuiProposalSize(rawUnspecified) == unspecified)

    let widthOnly = WaterUI.WuiProposalSize(width: 120, height: nil)
    let rawWidthOnly = widthOnly.toCStruct()
    #expect(rawWidthOnly.width == 120)
    #expect(rawWidthOnly.height.isNaN)
    #expect(WaterUI.WuiProposalSize(rawWidthOnly) == widthOnly)
  }

  /// NaN means ideal while infinity queries the maximum; the ABI must keep
  /// these semantically different offers distinct on each axis.
  @Test func proposalDistinguishesIdealAndMaximumAxes() {
    let raw = CWaterUI.WuiProposalSize(
      width: Float.nan,
      height: Float.infinity
    )
    let proposal = WaterUI.WuiProposalSize(raw)
    #expect(proposal.width == nil)
    #expect(proposal.height == Float.infinity)
  }

  // MARK: - Layout priority metadata

  /// `.layout_priority(n)` exists to replace the child's own priority in the
  /// parent's space distribution — forwarding the child's value instead would
  /// make the metadata a no-op.
  @Test func layoutPriorityReportsTheOverrideNotTheContents() {
    let content = RecordingContentView()
    let wrapper = WuiLayoutPriority(contentView: content, priority: 42)
    #expect(wrapper.layoutPriority() == 42)
  }

  /// The wrapper is transparent for layout: everything but the priority
  /// report belongs to the content — the placement proposal lands verbatim,
  /// measurement forwards, and the stretch axis is the child's.
  @Test func layoutPriorityWrapperIsTransparentForPlacement() {
    let content = RecordingContentView()
    let wrapper = WuiLayoutPriority(contentView: content, priority: -3)
    let offer = WaterUI.WuiProposalSize(width: 200, height: nil)

    wrapper.setPlacementProposal(offer)
    #expect(content.placedProposals == [offer])

    _ = wrapper.sizeThatFits(offer)
    #expect(content.measuredProposals == [offer])
    #expect(wrapper.stretchAxis == content.stretchAxis)
  }

  /// A probe sequence can offer several proposals; the delivered one is the
  /// last value sent, and earlier probes must not accumulate into layout —
  /// the recording sees exactly what the parent selected each time.
  @Test func reorderedProbesDeliverOnlyTheSelectedProposal() {
    let content = RecordingContentView()
    let wrapper = WuiLayoutPriority(contentView: content, priority: 0)

    wrapper.setPlacementProposal(WaterUI.WuiProposalSize(width: 300, height: nil))
    wrapper.setPlacementProposal(WaterUI.WuiProposalSize(width: 0, height: nil))
    wrapper.setPlacementProposal(WaterUI.WuiProposalSize(width: 150, height: nil))

    #expect(content.placedProposals == [
      WaterUI.WuiProposalSize(width: 300, height: nil),
      WaterUI.WuiProposalSize(width: 0, height: nil),
      WaterUI.WuiProposalSize(width: 150, height: nil),
    ])
    #expect(content.placedProposals.last == WaterUI.WuiProposalSize(width: 150, height: nil))
  }

  // MARK: - Spacer and FFI surface

  /// The framework's `Spacer::DEFAULT_LAYOUT_PRIORITY` sits below every real
  /// priority band — a spacer yields all siblings before taking space.
  @Test func spacerDefaultPriorityIsTheFrameworkConstant() {
    let spacer = WuiSpacer(stretchAxis: .mainAxis)
    #expect(spacer.layoutPriority() == Int32.min)

    let proxy = SubViewProxy(
      stretchAxis: .both,
      priority: spacer.layoutPriority()
    ) { _ in
      WuiViewDimensions(size: .zero)
    }
    #expect(proxy.toBorrowedWuiSubView().priority == Int32.min)
  }

  /// `waterui_layout_stretch_axis` answers from the children's current axes —
  /// the FFI array the Swift side feeds it must carry them verbatim.
  @Test func stretchAxisQueryCarriesChildAxesVerbatim() {
    let axes = WaterUI.WuiArray<CWaterUI.WuiStretchAxis>(array: [
      CWaterUI.WuiStretchAxis(rawValue: 0),
      CWaterUI.WuiStretchAxis(rawValue: 1),
      CWaterUI.WuiStretchAxis(rawValue: 3),
    ])
    let ffiArray = axes.intoWuiStretchAxisArray()
    let raw = unsafeBitCast(ffiArray, to: CWaterUI.WuiArray.self)
    let roundTripped = WaterUI.WuiArray<CWaterUI.WuiStretchAxis>(c: raw).map { $0.rawValue }
    #expect(roundTripped == [0, 1, 3])
  }
}
