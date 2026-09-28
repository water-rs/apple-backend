import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

// MARK: - WuiDragPayloadBox

/// An owned `WuiDragPayload` handle travelling with a drag inside the process.
///
/// Platform-representable payloads (text, URL, files) are also written to the
/// pasteboard so other applications can receive them; the handle itself is how
/// a same-process drop destination receives the typed value unserialized.
/// `InProcess` payloads have no pasteboard representation — only the box moves.
final class WuiDragPayloadBox {
  let payload: OpaquePointer

  init(payload: OpaquePointer) {
    self.payload = payload
  }

  deinit {
    waterui_drop_drag_payload(payload)
  }
}

/// Pasteboard type marking a drag whose payload stays inside the process. The
/// marker carries no data: a same-process destination reads the `WuiDragPayload`
/// handle off the drag item's `localObject` (iOS) or the dragging source
/// (macOS). Drags from other applications never carry it.
let wuiInProcessPasteboardType = "dev.waterui.inProcessDragPayload"

// MARK: - WuiDraggable

/// Component for Metadata<Draggable>.
///
/// Makes the wrapped view draggable for native drag and drop operations.
/// On macOS, uses NSDragging protocols.
/// On iOS, uses UIDragInteraction.
@MainActor
final class WuiDraggable: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_draggable_id() }

  private let contentView: any WuiComponent
  private let draggable: CWaterUI.WuiDraggable
  private let env: WuiEnvironment

  /// The payload of the drag currently in flight from this view. Same-process
  /// drop destinations read it off the dragging source to deliver the typed
  /// value unserialized; it clears when the drag session ends.
  private(set) var activePayload: WuiDragPayloadBox?

  var stretchAxis: WuiStretchAxis {
    contentView.stretchAxis
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_draggable(anyview)

    self.env = env
    self.draggable = metadata.value
    self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

    super.init(frame: .zero)

    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)

    #if canImport(UIKit)
      // iOS: Use UIDragInteraction
      let dragInteraction = UIDragInteraction(delegate: self)
      dragInteraction.isEnabled = true
      self.addInteraction(dragInteraction)
      self.isUserInteractionEnabled = true
    #endif
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @MainActor deinit {
    var mutableDraggable = draggable
    waterui_drop_draggable(&mutableDraggable)
  }

  /// Reads the payload a drag starting now carries. The box owns the FFI
  /// handle and releases it with `waterui_drop_drag_payload`.
  private func beginPayload() -> WuiDragPayloadBox {
    var mutableDraggable = draggable
    guard let payload = waterui_draggable_payload(&mutableDraggable) else {
      fatalError("waterui_draggable_payload returned null")
    }
    return WuiDragPayloadBox(payload: payload)
  }

  private func payloadText(_ payload: OpaquePointer) -> String {
    WuiStr(waterui_drag_payload_text(payload)).toString()
  }

  private func payloadURL(_ payload: OpaquePointer) -> URL {
    let value = WuiStr(waterui_drag_payload_url(payload)).toString()
    guard let url = URL(string: value) else {
      fatalError("WaterUI draggable contains an invalid URL: \(value)")
    }
    return url
  }

  private func payloadFileURLs(_ payload: OpaquePointer) -> [URL] {
    WuiArray<CWaterUI.WuiStr>(waterui_drag_payload_files(payload)).map {
      let value = WuiStr($0).toString()
      guard let url = URL(string: value) else {
        fatalError("WaterUI draggable contains an invalid file URL: \(value)")
      }
      return url
    }
  }

  func layoutPriority() -> Int32 {
    contentView.layoutPriority()
  }

  /// Transparent for layout: the proposal selected for this
  /// wrapper is the proposal its content was negotiated with.
  func setPlacementProposal(_ proposal: WuiProposalSize) {
    contentView.setPlacementProposal(proposal)
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    contentView.sizeThatFits(proposal)
  }

  func measure(_ proposal: WuiProposalSize) -> WuiViewDimensions {
    contentView.measure(proposal)
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      contentView.frame = bounds
    }
  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      contentView.frame = bounds
    }

    // MARK: - macOS Drag Source

    private var dragOrigin: NSPoint?

    override func mouseDown(with event: NSEvent) {
      dragOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
      guard let origin = dragOrigin else { return }

      let current = event.locationInWindow
      let distance = hypot(current.x - origin.x, current.y - origin.y)

      // Only start drag after moving a minimum distance (3 points)
      guard distance > 3 else { return }

      dragOrigin = nil  // Prevent re-triggering

      let box = beginPayload()
      activePayload = box

      let pasteboardItems: [NSPasteboardItem]
      switch waterui_drag_payload_kind(box.payload) {
      case WuiTransferKind_Text:
        let item = NSPasteboardItem()
        item.setString(payloadText(box.payload), forType: .string)
        pasteboardItems = [item]
      case WuiTransferKind_Url:
        let item = NSPasteboardItem()
        item.setString(payloadURL(box.payload).absoluteString, forType: .URL)
        pasteboardItems = [item]
      case WuiTransferKind_Files:
        // One dragging item per file URL, matching Finder.
        pasteboardItems = payloadFileURLs(box.payload).map { url in
          let item = NSPasteboardItem()
          item.setString(url.absoluteString, forType: .fileURL)
          return item
        }
      case WuiTransferKind_InProcess:
        // No pasteboard representation: the marker merely routes the drag to
        // same-process destinations, which read the payload off this source.
        let item = NSPasteboardItem()
        item.setString("", forType: NSPasteboard.PasteboardType(wuiInProcessPasteboardType))
        pasteboardItems = [item]
      default:
        fatalError(
          "Unsupported WaterUI transfer kind: \(waterui_drag_payload_kind(box.payload).rawValue)")
      }

      let draggingItems = pasteboardItems.map { item -> NSDraggingItem in
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: snapshot())
        return draggingItem
      }

      beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
      dragOrigin = nil
    }

    private func snapshot() -> NSImage {
      let image = NSImage(size: bounds.size)
      image.lockFocus()
      if let ctx = NSGraphicsContext.current?.cgContext {
        // Flip the context since NSView.isFlipped = true but CGContext is not flipped
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        layer?.render(in: ctx)
      }
      image.unlockFocus()
      return image
    }
  #endif
}

#if canImport(AppKit)
  extension WuiDraggable: NSDraggingSource {
    func draggingSession(
      _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
      return [.copy, .move]
    }

    func draggingSession(
      _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
      activePayload = nil
    }
  }
#endif

#if canImport(UIKit)
  extension WuiDraggable: UIDragInteractionDelegate {
    func dragInteraction(
      _ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession
    ) -> [UIDragItem] {
      let box = beginPayload()

      let itemProviders: [NSItemProvider]
      switch waterui_drag_payload_kind(box.payload) {
      case WuiTransferKind_Text:
        itemProviders = [NSItemProvider(object: payloadText(box.payload) as NSString)]
      case WuiTransferKind_Url:
        itemProviders = [NSItemProvider(object: payloadURL(box.payload) as NSURL)]
      case WuiTransferKind_Files:
        itemProviders = payloadFileURLs(box.payload).map { NSItemProvider(object: $0 as NSURL) }
      case WuiTransferKind_InProcess:
        // The payload has no cross-process representation: a process-scoped
        // marker keeps the item well-formed while the payload travels in
        // `localObject` only.
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
          forTypeIdentifier: wuiInProcessPasteboardType, visibility: .ownProcess
        ) { completion in
          completion(Data(), nil)
          return nil
        }
        itemProviders = [provider]
      default:
        fatalError(
          "Unsupported WaterUI transfer kind: \(waterui_drag_payload_kind(box.payload).rawValue)")
      }

      return itemProviders.map { provider in
        let dragItem = UIDragItem(itemProvider: provider)
        // Same-process drop destinations read the payload handle off the item.
        dragItem.localObject = box
        return dragItem
      }
    }
  }
#endif
