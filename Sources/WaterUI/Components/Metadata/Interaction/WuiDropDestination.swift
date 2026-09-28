import CWaterUI

#if canImport(UIKit)
  import UIKit
  import UniformTypeIdentifiers
#elseif canImport(AppKit)
  import AppKit
#endif

// MARK: - WuiDropDestination

/// Component for Metadata<DropDestination>.
///
/// Makes the wrapped view a drop destination for drag and drop operations.
/// The destination's accepted `WuiTransferKind` selects which pasteboard types
/// it registers for and which dropped values it delivers; `InProcess`
/// destinations accept only same-process drags carrying a payload handle.
/// On macOS, uses NSDraggingDestination protocol.
/// On iOS, uses UIDropInteraction.
@MainActor
final class WuiDropDestination: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_drop_destination_id() }

  private let contentView: any WuiComponent
  private let dropDest: CWaterUI.WuiDropDestination
  private let acceptedKind: CWaterUI.WuiTransferKind
  private let env: WuiEnvironment

  var stretchAxis: WuiStretchAxis {
    contentView.stretchAxis
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_drop_destination(anyview)

    self.env = env
    self.dropDest = metadata.value
    self.acceptedKind = metadata.value.accepted_kind
    self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

    super.init(frame: .zero)

    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)

    #if canImport(UIKit)
      // iOS: Use UIDropInteraction
      let dropInteraction = UIDropInteraction(delegate: self)
      self.addInteraction(dropInteraction)
      self.isUserInteractionEnabled = true
    #elseif canImport(AppKit)
      // macOS: Register for the pasteboard types the accepted kind maps to. An
      // `InProcess` destination registers for the private marker only: its
      // payload never takes pasteboard form.
      switch acceptedKind {
      case WuiTransferKind_Text:
        registerForDraggedTypes([.string])
      case WuiTransferKind_Url:
        registerForDraggedTypes([.URL])
      case WuiTransferKind_Files:
        registerForDraggedTypes([.fileURL])
      case WuiTransferKind_InProcess:
        registerForDraggedTypes([NSPasteboard.PasteboardType(wuiInProcessPasteboardType)])
      default:
        break
      }
    #endif
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @MainActor deinit {
    var mutableDest = dropDest
    waterui_drop_drop_destination(&mutableDest)
  }

  /// Whether `payload` is accepted; the check includes `InProcess` type
  /// identity, so same-process payload handles must go through it.
  private func accepts(_ payload: OpaquePointer) -> Bool {
    var mutableDest = dropDest
    return waterui_drop_destination_accepts(&mutableDest, payload)
  }

  /// Delivers a payload the destination accepts; the caller keeps ownership.
  private func deliver(_ payload: OpaquePointer) {
    var mutableDest = dropDest
    waterui_call_drop_handler(&mutableDest, env.inner, payload)
  }

  /// Delivers an owning payload built from dropped platform data, releasing it
  /// afterwards.
  private func deliverOwned(_ payload: OpaquePointer) {
    deliver(payload)
    waterui_drop_drag_payload(payload)
  }

  private func deliverText(_ text: String) {
    deliverOwned(waterui_drag_payload_from_text(WuiStr(string: text).intoInner()))
  }

  private func deliverURL(_ url: URL) {
    deliverOwned(waterui_drag_payload_from_url(WuiStr(string: url.absoluteString).intoInner()))
  }

  private func deliverFiles(_ urls: [URL]) {
    let strings = urls.map { WuiStr(string: $0.absoluteString).intoInner() }
    deliverOwned(
      waterui_drag_payload_from_files(
        WuiArray<CWaterUI.WuiStr>(array: strings).intoWuiStrArray()))
  }

  private func callEnterHandler() {
    var mutableDest = dropDest
    waterui_call_drop_enter_handler(&mutableDest, env.inner)
  }

  private func callExitHandler() {
    var mutableDest = dropDest
    waterui_call_drop_exit_handler(&mutableDest, env.inner)
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

    // MARK: - macOS Drop Destination

    /// Whether the drag over this view is acceptable. A drag from a WaterUI
    /// draggable in the same process carries its payload handle on the source
    /// view — the FFI check then also discriminates `InProcess` type identity.
    /// Any other drag is judged by the pasteboard types it offers.
    private func isAccepted(_ sender: any NSDraggingInfo) -> Bool {
      if let source = sender.draggingSource as? WuiDraggable,
        let box = source.activePayload
      {
        return accepts(box.payload)
      }

      let types = sender.draggingPasteboard.types ?? []
      switch acceptedKind {
      case WuiTransferKind_Text:
        return types.contains(.string)
      case WuiTransferKind_Url:
        return types.contains(.URL)
      case WuiTransferKind_Files:
        return types.contains(.fileURL)
      case WuiTransferKind_InProcess:
        return false
      default:
        return false
      }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
      guard isAccepted(sender) else { return [] }
      callEnterHandler()
      return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
      return isAccepted(sender) ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
      guard let sender, isAccepted(sender) else { return }
      callExitHandler()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
      // A same-process drag delivers its payload handle directly: the typed
      // value reaches the handler unserialized.
      if let source = sender.draggingSource as? WuiDraggable,
        let box = source.activePayload,
        accepts(box.payload)
      {
        deliver(box.payload)
        return true
      }

      let pasteboard = sender.draggingPasteboard
      switch acceptedKind {
      case WuiTransferKind_Files:
        guard
          let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
          !urls.isEmpty
        else { return false }
        deliverFiles(urls)
        return true
      case WuiTransferKind_Url:
        guard let value = pasteboard.string(forType: .URL), let url = URL(string: value)
        else { return false }
        deliverURL(url)
        return true
      case WuiTransferKind_Text:
        guard let string = pasteboard.string(forType: .string) else { return false }
        deliverText(string)
        return true
      case WuiTransferKind_InProcess:
        // Only a same-process drag can produce this kind; handled above.
        return false
      default:
        return false
      }
    }
  #endif
}

#if canImport(UIKit)
  extension WuiDropDestination: UIDropInteractionDelegate {
    /// The payload of an accepted same-process drag item, if any. Other
    /// applications' drags carry no `WuiDragPayloadBox`.
    private func acceptedLocalPayload(in session: any UIDropSession) -> OpaquePointer? {
      session.localDragSession?.items.lazy
        .compactMap { ($0.localObject as? WuiDragPayloadBox)?.payload }
        .first(where: { accepts($0) })
    }

    private func isAcceptable(_ session: any UIDropSession) -> Bool {
      if acceptedLocalPayload(in: session) != nil {
        return true
      }
      switch acceptedKind {
      case WuiTransferKind_Text:
        return session.canLoadObjects(ofClass: NSString.self)
      case WuiTransferKind_Url:
        return session.canLoadObjects(ofClass: NSURL.self)
      case WuiTransferKind_Files:
        return session.hasItemsConforming(toTypeIdentifiers: [UTType.fileURL.identifier])
      case WuiTransferKind_InProcess:
        // No pasteboard type can produce this kind.
        return false
      default:
        return false
      }
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession)
      -> Bool
    {
      return isAcceptable(session)
    }

    func dropInteraction(
      _ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession
    ) -> UIDropProposal {
      return UIDropProposal(operation: isAcceptable(session) ? .copy : .forbidden)
    }

    func dropInteraction(
      _ interaction: UIDropInteraction, sessionDidEnter session: any UIDropSession
    ) {
      guard isAcceptable(session) else { return }
      callEnterHandler()
    }

    func dropInteraction(
      _ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession
    ) {
      guard isAcceptable(session) else { return }
      callExitHandler()
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
      // A same-process drag delivers its payload handle directly.
      if let payload = acceptedLocalPayload(in: session) {
        deliver(payload)
        return
      }

      switch acceptedKind {
      case WuiTransferKind_Files:
        guard session.hasItemsConforming(toTypeIdentifiers: [UTType.fileURL.identifier])
        else { return }
        _ = session.loadObjects(ofClass: NSURL.self) { [weak self] objects in
          let urls = objects.compactMap { $0 as? URL }.filter { $0.isFileURL }
          guard !urls.isEmpty else { return }
          self?.deliverFiles(urls)
        }
      case WuiTransferKind_Url:
        guard session.canLoadObjects(ofClass: NSURL.self) else { return }
        _ = session.loadObjects(ofClass: NSURL.self) { [weak self] objects in
          guard let url = objects.first as? URL else { return }
          self?.deliverURL(url)
        }
      case WuiTransferKind_Text:
        guard session.canLoadObjects(ofClass: NSString.self) else { return }
        _ = session.loadObjects(ofClass: NSString.self) { [weak self] objects in
          guard let string = objects.first as? String else { return }
          self?.deliverText(string)
        }
      case WuiTransferKind_InProcess:
        break
      default:
        break
      }
    }
  }
#endif
