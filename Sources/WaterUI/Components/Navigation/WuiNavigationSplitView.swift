import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
final class WuiNavigationSplitView: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_split_navigation_container_id() }

  private(set) var stretchAxis: WuiStretchAxis = .both

  private let sidebarView: WuiAnyView
  private let placeholderView: WuiAnyView
  private let selectionBinding: WuiBinding<Int32>
  private let detailHandle: UnsafeMutablePointer<CWaterUI.WuiNavigationSplitDetail>
  private let env: WuiEnvironment
  private let sidebarWidth: CGFloat
  private var detailView: WuiNavigationView?
  private var selectionWatcher: WatcherGuard?

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let ffiSplit = waterui_force_as_split_navigation_container(anyview)
    guard
      let sidebar = ffiSplit.sidebar,
      let placeholder = ffiSplit.placeholder,
      let selection = ffiSplit.selection,
      let detail = ffiSplit.detail
    else {
      fatalError("NavigationSplitLayout requires sidebar, placeholder, selection, and detail")
    }

    self.init(
      sidebarView: WuiAnyView(anyview: sidebar, env: env),
      placeholderView: WuiAnyView(anyview: placeholder, env: env),
      selectionBinding: WuiBinding<Int32>(selection),
      detailHandle: detail,
      env: env,
      sidebarWidth: CGFloat(ffiSplit.sidebar_width),
    )
  }

  init(
    sidebarView: WuiAnyView,
    placeholderView: WuiAnyView,
    selectionBinding: WuiBinding<Int32>,
    detailHandle: UnsafeMutablePointer<CWaterUI.WuiNavigationSplitDetail>,
    env: WuiEnvironment,
    sidebarWidth: CGFloat,
  ) {
    guard sidebarWidth.isFinite, sidebarWidth > 0 else {
      fatalError("NavigationSplitLayout sidebar width must be finite and positive")
    }

    self.sidebarView = sidebarView
    self.placeholderView = placeholderView
    self.selectionBinding = selectionBinding
    self.detailHandle = detailHandle
    self.env = env
    self.sidebarWidth = sidebarWidth
    super.init(frame: .zero)

    sidebarView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(sidebarView)

    placeholderView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(placeholderView)

    selectionWatcher = selectionBinding.watch { [weak self] _, _ in
      self?.syncDetailView()
      #if canImport(UIKit)
        self?.setNeedsLayout()
      #elseif canImport(AppKit)
        self?.needsLayout = true
      #endif
    }
    syncDetailView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @MainActor deinit {
    waterui_drop_split_navigation_detail(detailHandle)
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    let width = proposal.width.map(CGFloat.init) ?? 320
    let height = proposal.height.map(CGFloat.init) ?? 480
    return CGSize(width: width, height: height)
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      performLayout()
    }
  #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      performLayout()
    }
  #endif

  private func performLayout() {
    let compact = bounds.width < compactThreshold()

    if compact {
      let showsDetail = detailView != nil
      sidebarView.isHidden = showsDetail
      sidebarView.frame = bounds

      placeholderView.isHidden = true
      placeholderView.frame = .zero

      if let detailView {
        detailView.setBackAction(
          Action(callback: { [weak self] in
            self?.selectionBinding.set(0)
          }))
        detailView.isHidden = false
        detailView.frame = bounds
      }
      return
    }

    let actualSidebarWidth = min(sidebarWidth, bounds.width * 0.5)
    let sidebarFrame = CGRect(x: 0, y: 0, width: actualSidebarWidth, height: bounds.height)
    let detailFrame = CGRect(
      x: actualSidebarWidth,
      y: 0,
      width: bounds.width - actualSidebarWidth,
      height: bounds.height
    )

    sidebarView.isHidden = false
    sidebarView.frame = sidebarFrame

    if let detailView {
      detailView.setBackAction(nil)
      detailView.isHidden = false
      detailView.frame = detailFrame
      placeholderView.isHidden = true
      placeholderView.frame = .zero
    } else {
      placeholderView.isHidden = false
      placeholderView.frame = detailFrame
    }
  }

  private func compactThreshold() -> CGFloat {
    sidebarWidth + 360
  }

  private func syncDetailView() {
    detailView?.removeFromSuperview()
    detailView = nil

    let selected = selectionBinding.value
    if selected == 0 {
      return
    }

    let nav = waterui_split_navigation_detail_content(
      detailHandle,
      CWaterUI.WuiId(inner: selected),
      env.inner
    )
    let view = WuiNavigationView(ffiNav: nav, env: env)
    view.translatesAutoresizingMaskIntoConstraints = true
    addSubview(view)
    detailView = view
  }
}
