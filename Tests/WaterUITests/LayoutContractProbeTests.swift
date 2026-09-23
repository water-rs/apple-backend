import AppKit
import Foundation
import SwiftUI
import Synchronization
import Testing

private struct SpacerProbeEvent: Encodable, Sendable {
  let kind: String
  let name: String
  let proposalWidth: String
  let x: Double
  let width: Double
  let priority: Double?
}

private final class SpacerProbeTrace: Sendable {
  private let storage = Mutex<[SpacerProbeEvent]>([])
  var events: [SpacerProbeEvent] { storage.withLock { $0 } }

  func record(_ kind: String, _ name: String, _ proposal: ProposedViewSize, _ bounds: CGRect, priority: Double? = nil) {
    let event = SpacerProbeEvent(
      kind: kind, name: name,
      proposalWidth: proposal.width.map { String(describing: $0) } ?? "unspecified",
      x: Double(bounds.minX), width: Double(bounds.width), priority: priority
    )
    storage.withLock { $0.append(event) }
  }
}

private struct SpacerProbeRecorder: Layout {
  let name: String
  let trace: SpacerProbeTrace

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let size = subviews[0].sizeThatFits(proposal)
    trace.record("measure", name, proposal, CGRect(origin: .zero, size: size))
    return size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    trace.record("place", name, proposal, bounds)
    subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
  }
}

private struct SpacerProbeStack: Layout {
  typealias Cache = AnyLayout.Cache
  static var layoutProperties: LayoutProperties { HStackLayout.layoutProperties }
  let trace: SpacerProbeTrace
  private let layout = AnyLayout(HStackLayout(alignment: .top, spacing: 10))

  func makeCache(subviews: Subviews) -> Cache {
    layout.makeCache(subviews: subviews)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
    for (index, subview) in subviews.enumerated() {
      trace.record("priority", String(index), proposal, .zero, priority: subview.priority)
    }
    return layout.sizeThatFits(proposal: proposal, subviews: subviews, cache: &cache)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
    layout.placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &cache)
  }
}

private struct SpacerProbeProposal: Layout {
  let offered: ProposedViewSize
  let trace: SpacerProbeTrace

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let size = subviews[0].sizeThatFits(offered)
    trace.record("root-measure", "root", offered, CGRect(origin: .zero, size: size))
    return size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let size = subviews[0].sizeThatFits(offered)
    trace.record("root-place", "root", offered, CGRect(origin: bounds.origin, size: size))
    subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: offered)
  }
}

private struct SpacerProbeCase: Encodable {
  let mainProposal: String
  let events: [SpacerProbeEvent]
}

@MainActor
struct LayoutContractProbeTests {
  @Test func captureSpacerAlongsideCompressibleContent() throws {
    let output = try #require(ProcessInfo.processInfo.environment["WATERUI_LAYOUT_PROBE_OUTPUT"])
    var cases: [SpacerProbeCase] = []
    for main: CGFloat? in [nil, 80, 100, 140, 160, 240] {
      let trace = SpacerProbeTrace()
      let proposal = ProposedViewSize(width: main, height: 40)
      let root = SpacerProbeProposal(offered: proposal, trace: trace) {
        SpacerProbeStack(trace: trace) {
          SpacerProbeRecorder(name: "left", trace: trace) {
            Color.clear.frame(minWidth: 0, idealWidth: 60, maxWidth: 60, minHeight: 20, idealHeight: 20, maxHeight: 20)
          }
          Spacer(minLength: 0)
          SpacerProbeRecorder(name: "right", trace: trace) {
            Color.clear.frame(minWidth: 0, idealWidth: 60, maxWidth: 60, minHeight: 20, idealHeight: 20, maxHeight: 20)
          }
        }
      }
      let host = NSHostingView(rootView: root)
      host.sizingOptions = []
      host.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
      host.needsLayout = true
      host.layoutSubtreeIfNeeded()
      #expect(trace.events.contains { $0.kind == "place" && $0.name == "left" })
      #expect(trace.events.contains { $0.kind == "place" && $0.name == "right" })
      cases.append(SpacerProbeCase(
        mainProposal: main.map { String(describing: $0) } ?? "unspecified", events: trace.events
      ))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "+infinity", negativeInfinity: "-infinity", nan: "nan")
    try encoder.encode(cases).write(to: URL(fileURLWithPath: output), options: .atomic)
  }
}
