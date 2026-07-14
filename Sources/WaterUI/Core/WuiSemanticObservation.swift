import CWaterUI

@MainActor
final class WuiSemanticTextObservation {
  private let content: WuiComputedObservation<WuiStyledStr>
  private let paragraphAlignment: OpaquePointer?

  var styled: WuiStyledStr { content.value }
  var string: String { styled.toString() }

  init(
    consuming text: CWaterUI.WuiText,
    onChange: @escaping (WuiStyledStr, WuiWatcherMetadata) -> Void
  ) {
    guard let content = text.content else {
      fatalError("Semantic text content computed pointer is null")
    }
    self.paragraphAlignment = text.paragraph_alignment
    self.content = WuiComputedObservation(WuiComputed<WuiStyledStr>(content), onChange: onChange)
  }

  @MainActor deinit {
    if let paragraphAlignment {
      waterui_drop_computed_horizontal_alignment(paragraphAlignment)
    }
  }
}

@MainActor
final class WuiStableSemanticCollection<ID: Hashable, Node: AnyObject> {
  private var nodesById: [ID: Node] = [:]
  private(set) var ordered: [Node] = []

  @discardableResult
  func reconcile(
    ids: [ID],
    create: (Int, ID) -> Node
  ) -> [Node] {
    var next: [ID: Node] = [:]
    next.reserveCapacity(ids.count)
    var ordered: [Node] = []
    ordered.reserveCapacity(ids.count)
    for (index, id) in ids.enumerated() {
      let node = nodesById[id] ?? create(index, id)
      next[id] = node
      ordered.append(node)
    }
    nodesById = next
    self.ordered = ordered
    return ordered
  }
}

@MainActor
final class WuiStableViewCollection {
  private let source: WuiAnyViews
  private let env: WuiEnvironment
  private let nodes = WuiStableSemanticCollection<Int32, WuiAnyView>()
  private var watcher: WatcherGuard?

  private(set) var ordered: [WuiAnyView] = []

  init(
    consuming source: OpaquePointer,
    env: WuiEnvironment,
    onChange: @escaping (WuiWatcherMetadata) -> Void
  ) {
    self.source = WuiAnyViews(source)
    self.env = env
    watcher = watchAnyViewsIds(self.source) { [weak self] ids, metadata in
      self?.reconcile(ids: ids)
      onChange(metadata)
    }
    reconcile(ids: self.source.allIds())
  }

  private func reconcile(ids: [Int32]) {
    ordered = nodes.reconcile(ids: ids) { [source, env] index, _ in
      source.getView(at: index, env: env)
    }
  }
}
