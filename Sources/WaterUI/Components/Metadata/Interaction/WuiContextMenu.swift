import CWaterUI
import Foundation

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

#if canImport(AppKit)
  /// `wuiContextMenuAccessoryFrame` in bottom-left screen coordinates: every
  /// rect is mirrored about `screenBounds` (the container is unchanged by the
  /// mirror), the top-left math runs, and the result is mirrored back. "Above
  /// the preview" lands at `previewFrame.maxY + gap`, where AppKit's
  /// bottom-left y grows upward.
  func wuiContextMenuAccessoryScreenFrame(
    previewFrame: CGRect,
    accessorySize: CGSize,
    screenBounds: CGRect,
    gap: CGFloat = 8,
    edgeMargin: CGFloat = 8
  ) -> CGRect {
    func mirror(_ rect: CGRect) -> CGRect {
      CGRect(
        x: rect.minX,
        y: screenBounds.minY + screenBounds.maxY - rect.maxY,
        width: rect.width,
        height: rect.height
      )
    }
    return mirror(
      wuiContextMenuAccessoryFrame(
        previewFrame: mirror(previewFrame),
        accessorySize: accessorySize,
        containerBounds: screenBounds,
        gap: gap,
        edgeMargin: edgeMargin
      )
    )
  }
#endif

/// The accessory's frame: centred on the lifted preview's top edge, inside
/// `containerBounds` with `edgeMargin` of air. When the space above the
/// preview cannot hold the accessory it sits below the preview instead, and
/// when neither edge has room it is clamped inside the container. Sizes wider
/// or taller than the container are clipped to it first.
///
/// The math is written for a top-left coordinate space — "above" is
/// `previewFrame.minY - gap - height`. macOS screen coordinates grow the other
/// way, so AppKit mirrors the screen rects about the bounds before calling
/// this (see `wuiContextMenuAccessoryScreenFrame`).
func wuiContextMenuAccessoryFrame(
  previewFrame: CGRect,
  accessorySize: CGSize,
  containerBounds: CGRect,
  gap: CGFloat = 8,
  edgeMargin: CGFloat = 8
) -> CGRect {
  let width = min(accessorySize.width, max(0, containerBounds.width - 2 * edgeMargin))
  let height = min(accessorySize.height, max(0, containerBounds.height - 2 * edgeMargin))
  let innerBounds = containerBounds.insetBy(dx: edgeMargin, dy: edgeMargin)

  var x = previewFrame.midX - width / 2
  x = min(max(x, innerBounds.minX), max(innerBounds.minX, innerBounds.maxX - width))

  var y = previewFrame.minY - gap - height
  if y < innerBounds.minY {
    y = previewFrame.maxY + gap
  }
  if y + height > innerBounds.maxY {
    y = max(innerBounds.minY, innerBounds.maxY - height)
  }
  return CGRect(x: x, y: y, width: width, height: height)
}

/// Turns the dismiss-request counter into a menu close. The counter's initial
/// value is not a request — the signal delivers only on change, so every
/// callback closes the open menu and drops the accessory.
@MainActor
final class WuiContextMenuDismissal {
  private var watcher: WatcherGuard?

  init(requests: WuiComputed<Int32>, dismiss: @escaping () -> Void) {
    watcher = requests.watch { _, _ in dismiss() }
  }
}

@MainActor
final class WuiContextMenu: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_context_menu_id() }

  private let contentView: any WuiComponent
  private let env: WuiEnvironment
  private let dismissRequests: WuiComputed<Int32>
  private var dismissal: WuiContextMenuDismissal!
  private var tree: WuiMenuTree!

  #if canImport(UIKit)
    /// The view lifted while the menu is open; nil lifts the source view.
    private let previewView: WuiAnyView?
    /// The interactive accessory presented over the targeted preview.
    private let accessoryView: WuiAnyView?
    /// The overlay showing `accessoryView` while the interaction is displayed.
    private var accessoryWindow: WuiContextMenuAccessoryWindow?
    private var contextMenuInteraction: UIContextMenuInteraction?
  #elseif canImport(AppKit)
    /// The interactive accessory presented over the source view.
    private let accessoryView: WuiAnyView?
    /// The floating panel showing `accessoryView` while the menu tracks.
    private var accessoryPanel: NSPanel?
    /// The menu currently tracking, so a dismiss request can cancel it.
    private var openMenu: NSMenu?
  #endif

  var stretchAxis: WuiStretchAxis { contentView.stretchAxis }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_context_menu(anyview)
    guard let items = metadata.value.items else {
      fatalError("ContextMenu.items is null")
    }
    guard let dismissRequestsPointer = metadata.value.dismiss_requests else {
      fatalError("ContextMenu.dismiss_requests is null")
    }

    self.env = env
    self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)
    self.dismissRequests = WuiComputed<Int32>(dismissRequestsPointer)

    #if canImport(UIKit)
      self.previewView = metadata.value.preview.map { WuiAnyView(anyview: $0, env: env) }
      self.accessoryView = metadata.value.accessory.map { WuiAnyView(anyview: $0, env: env) }
    #elseif canImport(AppKit)
      self.accessoryView = metadata.value.accessory.map { WuiAnyView(anyview: $0, env: env) }
      // NSMenu has no preview slot: the lifted view is an iOS primitive. The
      // handle is released without being resolved.
      if let preview = metadata.value.preview {
        waterui_drop_anyview(preview)
      }
    #endif

    super.init(frame: .zero)

    tree = WuiMenuTree(consuming: items) { [weak self] _ in
      self?.invalidateCapturedRendering()
    }
    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)

    #if canImport(UIKit)
      let interaction = UIContextMenuInteraction(delegate: self)
      contextMenuInteraction = interaction
      addInteraction(interaction)
      isUserInteractionEnabled = true
    #endif

    dismissal = WuiContextMenuDismissal(requests: dismissRequests) { [weak self] in
      self?.dismissPresentedMenu()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// A dismiss request closes the open menu and drops the accessory. The
  /// platform teardown paths (`willEndFor`, `menuDidClose`) do the same, so
  /// `teardownAccessory` must stay idempotent.
  private func dismissPresentedMenu() {
    #if canImport(UIKit)
      contextMenuInteraction?.dismissMenu()
    #elseif canImport(AppKit)
      openMenu?.cancelTracking()
    #endif
    teardownAccessory()
  }

  func layoutPriority() -> Int32 { contentView.layoutPriority() }

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

    /// The frame the lifted preview occupies in window coordinates: the source
    /// view's frame, or the frame the targeted preview declares when a custom
    /// preview is set — centred on the source, at the preview's ideal size.
    private func targetedPreviewFrame() -> CGRect {
      let sourceFrame = convert(bounds, to: nil)
      guard let previewView else { return sourceFrame }
      let size = previewView.sizeThatFits(WuiProposalSize())
      return CGRect(
        x: sourceFrame.midX - size.width / 2,
        y: sourceFrame.midY - size.height / 2,
        width: size.width,
        height: size.height
      )
    }

    /// The preview the interaction lifts and returns to the source view: the
    /// rendered `preview` view when set, the source view otherwise.
    private func targetedPreview() -> UITargetedPreview {
      guard let previewView else {
        return UITargetedPreview(view: self)
      }
      // The highlight preview runs before `previewProvider` lays the view out;
      // give it its ideal bounds so the lift has something to snapshot.
      if previewView.bounds.isEmpty {
        previewView.bounds = CGRect(
          origin: .zero, size: previewView.sizeThatFits(WuiProposalSize()))
        previewView.layoutIfNeeded()
      }
      return UITargetedPreview(
        view: previewView,
        parameters: UIPreviewParameters(),
        target: UIPreviewTarget(
          container: self, center: CGPoint(x: bounds.midX, y: bounds.midY))
      )
    }

    /// Shows the accessory in its own window above the context menu's
    /// container, which sits inside the host window and would otherwise cover
    /// it. Only the accessory accepts touches — the window passes the rest
    /// through so outside taps still dismiss the menu.
    private func presentAccessory() {
      guard let accessoryView, accessoryWindow == nil,
        let hostWindow = window, let scene = hostWindow.windowScene
      else { return }

      let overlay = WuiContextMenuAccessoryWindow(
        windowScene: scene, hostWindow: hostWindow)
      overlay.present(
        accessory: accessoryView, previewFrame: targetedPreviewFrame())
      overlay.isHidden = false
      accessoryWindow = overlay
    }

    private func teardownAccessory() {
      accessoryWindow?.isHidden = true
      accessoryWindow = nil
    }

    /// A window above the context menu's that only the accessory hit-tests:
    /// hits outside the accessory fall through to the host window, where the
    /// menu container reads them as dismiss taps.
    private final class WuiContextMenuAccessoryWindow: UIWindow {
      private let platter = WuiContextMenuAccessoryPlatter()

      init(windowScene: UIWindowScene, hostWindow: UIWindow) {
        super.init(windowScene: windowScene)
        frame = hostWindow.frame
        windowLevel = UIWindow.Level(hostWindow.windowLevel.rawValue + 1)
        backgroundColor = .clear
        platter.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        platter.frame = bounds
        addSubview(platter)
      }

      func present(accessory: WuiAnyView, previewFrame: CGRect) {
        platter.present(accessory: accessory, previewFrame: previewFrame)
      }

      override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === platter ? nil : hit
      }
    }

    /// The overlay window's content: the accessory laid out against the lifted
    /// preview's frame, re-measured on every pass so a view that changes size
    /// (a strip that grows into a picker) is re-anchored.
    private final class WuiContextMenuAccessoryPlatter: UIView {
      private weak var accessory: WuiAnyView?
      private var previewFrame: CGRect = .zero

      func present(accessory: WuiAnyView, previewFrame: CGRect) {
        self.accessory?.removeFromSuperview()
        self.accessory = accessory
        self.previewFrame = previewFrame
        accessory.translatesAutoresizingMaskIntoConstraints = true
        addSubview(accessory)
        setNeedsLayout()
      }

      override func layoutSubviews() {
        super.layoutSubviews()
        guard let accessory else { return }
        accessory.frame = wuiContextMenuAccessoryFrame(
          previewFrame: previewFrame,
          accessorySize: accessory.sizeThatFits(WuiProposalSize()),
          containerBounds: bounds
        )
      }
    }
  #elseif canImport(AppKit)
    override func layout() {
      super.layout()
      contentView.frame = bounds
    }

    override func rightMouseDown(with event: NSEvent) {
      let menu = NSMenu()
      menu.delegate = self
      appendAppKitMenuItems(
        tree.nodes, to: menu, target: self, action: #selector(menuItemClicked(_:)))
      openMenu = menu
      NSMenu.popUpContextMenu(menu, with: event, for: self)
      openMenu = nil
    }

    /// The accessory's screen frame, anchored above the source view's rect in
    /// screen coordinates.
    private func accessoryScreenFrame(accessorySize: CGSize) -> CGRect {
      guard let window else { return .zero }
      let sourceScreen = window.convertToScreen(convert(bounds, to: nil))
      let screenBounds = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
      return wuiContextMenuAccessoryScreenFrame(
        previewFrame: sourceScreen,
        accessorySize: accessorySize,
        screenBounds: screenBounds
      )
    }

    /// A borderless, non-activating panel above the source view for the
    /// menu's tracking session, floating at the menu's level so it stays
    /// visible while the menu is open.
    private func presentAccessoryPanel() {
      guard let accessoryView, accessoryPanel == nil, window != nil else {
        return
      }
      let panel = NSPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
      )
      panel.isFloatingPanel = true
      panel.level = .popUpMenu
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = true
      panel.isReleasedWhenClosed = false
      let container = WuiContextMenuAccessoryContainer(
        accessory: accessoryView
      ) { [weak self, weak panel] size in
        guard let self, let panel else { return }
        panel.setFrame(self.accessoryScreenFrame(accessorySize: size), display: true)
      }
      panel.contentView = container
      panel.setFrame(
        accessoryScreenFrame(
          accessorySize: accessoryView.sizeThatFits(WuiProposalSize())),
        display: false
      )
      panel.orderFront(nil)
      accessoryPanel = panel
    }

    private func teardownAccessory() {
      accessoryPanel?.orderOut(nil)
      accessoryPanel = nil
    }

    /// The panel's content view: the accessory re-measured on every pass, so
    /// a view that changes size re-anchors the panel. `measuredSize` breaks
    /// the re-layout loop: a `setFrame` it triggers lands back here with the
    /// same size and stops.
    private final class WuiContextMenuAccessoryContainer: NSView {
      private let accessory: WuiAnyView
      private let onSizeChange: (CGSize) -> Void
      private var measuredSize = CGSize.zero

      init(accessory: WuiAnyView, onSizeChange: @escaping (CGSize) -> Void) {
        self.accessory = accessory
        self.onSizeChange = onSizeChange
        super.init(frame: .zero)
        wantsLayer = true
        accessory.translatesAutoresizingMaskIntoConstraints = true
        addSubview(accessory)
      }

      @available(*, unavailable)
      required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
      }

      nonisolated override var isFlipped: Bool { true }

      override func layout() {
        super.layout()
        accessory.frame = bounds
        let size = accessory.sizeThatFits(WuiProposalSize())
        if size != measuredSize {
          measuredSize = size
          onSizeChange(size)
        }
      }
    }

    @objc private func menuItemClicked(_ sender: NSMenuItem) {
      guard let action = sender.representedObject as? MenuActionRef else {
        fatalError("WaterUI context-menu item has no semantic action")
      }
      waterui_call_shared_action(action.command.action, env.inner)
    }
  #endif
}

#if canImport(UIKit)
  extension WuiContextMenu: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction,
      configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
      guard !tree.nodes.isEmpty else { return nil }
      return UIContextMenuConfiguration(
        identifier: nil,
        previewProvider: { [weak self] in
          self?.previewView.map { WuiContextMenuPreviewViewController(content: $0) }
        }
      ) { [weak self] _ in
        guard let self else { return nil }
        return buildUIKitMenu(title: "", from: self.tree.nodes) { [weak self] command in
          guard let self else { return }
          waterui_call_shared_action(command.action, self.env.inner)
        }
      }
    }

    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction,
      previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
      targetedPreview()
    }

    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction,
      previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
      targetedPreview()
    }

    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction,
      willDisplayMenuFor configuration: UIContextMenuConfiguration,
      animator: (any UIContextMenuInteractionAnimating)?
    ) {
      presentAccessory()
    }

    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction,
      willEndFor configuration: UIContextMenuConfiguration,
      animator: (any UIContextMenuInteractionAnimating)?
    ) {
      teardownAccessory()
    }
  }

  /// The context menu's preview content: the rendered `preview` view at its
  /// ideal size.
  @MainActor
  private final class WuiContextMenuPreviewViewController: UIViewController {
    private let content: WuiAnyView

    init(content: WuiAnyView) {
      self.content = content
      super.init(nibName: nil, bundle: nil)
      preferredContentSize = content.sizeThatFits(WuiProposalSize())
    }

    override func loadView() {
      view = content
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }
  }
#endif

#if canImport(AppKit)
  extension WuiContextMenu: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
      presentAccessoryPanel()
    }

    func menuDidClose(_ menu: NSMenu) {
      openMenu = nil
      // Deferred: the click that closed the menu may be addressed to the
      // accessory, and a panel ordered out in the same tick would eat it.
      DispatchQueue.main.async { [weak self] in
        self?.teardownAccessory()
      }
    }
  }
#endif
