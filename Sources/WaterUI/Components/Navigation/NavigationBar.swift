import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
struct WuiNavigationTitle {
  let view: WuiAnyView
  let text: String?
  let isPlainText: Bool
}

@MainActor
struct WuiNavigationSearch {
  let text: WuiBinding<WuiStr>
  let prompt: WuiComputed<WuiStyledStr>
  let env: WuiEnvironment
}

@MainActor
final class WuiNavigationSearchCoordinator: NSObject {
  private let search: WuiNavigationSearch
  private var textWatcher: WatcherGuard?
  private var promptWatcher: WatcherGuard?
  private var promptRenderer: WuiStyledStrRenderer?
  private var bodyFontObservation: WuiComputedObservation<WuiResolvedFontValue>?
  private var isSyncing = false

  init(search: WuiNavigationSearch) {
    self.search = search
  }

  #if canImport(UIKit)
    private weak var uiSearchBar: UISearchBar?

    func attach(searchBar: UISearchBar) {
      uiSearchBar = searchBar
      searchBar.delegate = self
      textWatcher = search.text.watch { [weak self] value, _ in
        self?.applyText(value.toString())
      }
      promptWatcher = search.prompt.watch { [weak self] value, _ in
        self?.applyPrompt(value)
      }
      bodyFontObservation = .bodyFont(env: search.env) { [weak self] font in
        self?.uiSearchBar?.searchTextField.font = font.toPlatformFont()
      }
      applyText(search.text.value.toString())
      applyPrompt(search.prompt.value)
    }

    func attach(searchController: UISearchController) {
      searchController.obscuresBackgroundDuringPresentation = false
      searchController.hidesNavigationBarDuringPresentation = false
      attach(searchBar: searchController.searchBar)
    }

    private func applyText(_ text: String) {
      guard let uiSearchBar else { return }
      guard uiSearchBar.text != text else { return }
      isSyncing = true
      uiSearchBar.text = text
      isSyncing = false
    }

    private func applyPrompt(_ prompt: WuiStyledStr) {
      promptRenderer = WuiStyledStrRenderer(
        styled: prompt,
        env: search.env,
        defaultForegroundSlot: WuiColorSlot_MutedForeground
      ) { [weak self] in
        self?.applyRenderedPrompt()
      }
      applyRenderedPrompt()
    }

    private func applyRenderedPrompt() {
      guard let uiSearchBar, let promptRenderer else { return }
      uiSearchBar.searchTextField.attributedPlaceholder = promptRenderer.attributedString()
      uiSearchBar.setNeedsLayout()
      uiSearchBar.superview?.setNeedsLayout()
    }
  #elseif canImport(AppKit)
    private weak var nsSearchField: NSSearchField?

    func attach(searchField: NSSearchField) {
      nsSearchField = searchField
      searchField.sendsSearchStringImmediately = true
      searchField.delegate = self
      textWatcher = search.text.watch { [weak self] value, _ in
        self?.applyText(value.toString())
      }
      promptWatcher = search.prompt.watch { [weak self] value, _ in
        self?.applyPrompt(value)
      }
      bodyFontObservation = .bodyFont(env: search.env) { [weak self] font in
        guard let field = self?.nsSearchField else { return }
        field.font = font.toPlatformFont()
        field.invalidateIntrinsicContentSize()
      }
      applyText(search.text.value.toString())
      applyPrompt(search.prompt.value)
    }

    private func applyText(_ text: String) {
      guard let nsSearchField else { return }
      guard nsSearchField.stringValue != text else { return }
      isSyncing = true
      nsSearchField.stringValue = text
      isSyncing = false
    }

    private func applyPrompt(_ prompt: WuiStyledStr) {
      promptRenderer = WuiStyledStrRenderer(
        styled: prompt,
        env: search.env,
        defaultForegroundSlot: WuiColorSlot_MutedForeground
      ) { [weak self] in
        self?.applyRenderedPrompt()
      }
      applyRenderedPrompt()
    }

    private func applyRenderedPrompt() {
      guard let nsSearchField, let promptRenderer else { return }
      nsSearchField.placeholderAttributedString = promptRenderer.attributedString()
      nsSearchField.invalidateIntrinsicContentSize()
      nsSearchField.superview?.needsLayout = true
    }
  #endif

  fileprivate func updateBinding(_ text: String) {
    guard !isSyncing else { return }
    search.text.set(WuiStr(string: text))
  }
}

#if canImport(UIKit)
  extension WuiNavigationSearchCoordinator: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
      updateBinding(searchText)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
      searchBar.resignFirstResponder()
    }
  }
#elseif canImport(AppKit)
  extension WuiNavigationSearchCoordinator: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else {
        fatalError("Navigation search delegate received unexpected control")
      }
      updateBinding(field.stringValue)
    }
  }
#endif

@MainActor
func makeInlineNavigationSearchView(
  _ search: WuiNavigationSearch
) -> (PlatformView, WuiNavigationSearchCoordinator) {
  let coordinator = WuiNavigationSearchCoordinator(search: search)
  #if canImport(UIKit)
    let searchBar = UISearchBar(frame: .zero)
    searchBar.searchBarStyle = .minimal
    coordinator.attach(searchBar: searchBar)
    return (searchBar, coordinator)
  #elseif canImport(AppKit)
    let searchField = NSSearchField(frame: .zero)
    coordinator.attach(searchField: searchField)
    return (searchField, coordinator)
  #endif
}

#if canImport(UIKit)
  @MainActor
  func makeNavigationSearchController(
    _ search: WuiNavigationSearch
  ) -> (UISearchController, WuiNavigationSearchCoordinator) {
    let controller = UISearchController(searchResultsController: nil)
    let coordinator = WuiNavigationSearchCoordinator(search: search)
    coordinator.attach(searchController: controller)
    return (controller, coordinator)
  }
#endif

@MainActor
struct WuiNavigationBarState {
  let title: WuiNavigationTitle
  let subtitle: WuiNavigationTitle
  let toolbar: [WuiNavigationToolbarItem]
  let search: WuiNavigationSearch?
  let color: WuiComputed<WuiResolvedColor>?
  let hidden: WuiComputed<Bool>?

  var leading: WuiAnyView? {
    toolbar.first {
      $0.placement == WuiNavigationToolbarPlacement_Cancellation
        || $0.placement == WuiNavigationToolbarPlacement_TopBarLeading
    }?.view
  }

  var trailing: WuiAnyView? {
    toolbar.first {
      $0.placement == WuiNavigationToolbarPlacement_PrimaryAction
        || $0.placement == WuiNavigationToolbarPlacement_SecondaryAction
        || $0.placement == WuiNavigationToolbarPlacement_Confirmation
        || $0.placement == WuiNavigationToolbarPlacement_TopBarTrailing
    }?.view
  }
}

@MainActor
struct WuiNavigationToolbarItem {
  let placement: WuiNavigationToolbarPlacement
  let view: WuiAnyView
}

@MainActor
func makeNavigationBarState(from bar: CWaterUI.WuiBar, env: WuiEnvironment) -> WuiNavigationBarState
{
  guard let titlePtr = bar.title else {
    fatalError("Navigation bar title pointer is null")
  }

  let title = makeNavigationTitle(from: titlePtr, env: env)
  guard let subtitlePtr = bar.subtitle else {
    fatalError("Navigation bar subtitle pointer is null")
  }
  let subtitle = makeNavigationTitle(from: subtitlePtr, env: env)
  let toolbar = WuiArray<CWaterUI.WuiNavigationToolbarItem>(bar.toolbar).map { item in
    guard let content = item.content else {
      fatalError("Navigation toolbar item content pointer is null")
    }
    return WuiNavigationToolbarItem(
      placement: item.placement,
      view: WuiAnyView(anyview: content, env: env)
    )
  }

  let color = bar.color.map(WuiComputed<WuiResolvedColor>.init)

  let hidden: WuiComputed<Bool>?
  if let hiddenPtr = bar.hidden {
    hidden = WuiComputed<Bool>(hiddenPtr)
  } else {
    hidden = nil
  }

  let search: WuiNavigationSearch?
  if bar.search.has_value {
    guard let text = bar.search.value.text else {
      fatalError("Navigation search text binding pointer is null")
    }
    guard let prompt = bar.search.value.prompt else {
      fatalError("Navigation search prompt computed pointer is null")
    }
    search = WuiNavigationSearch(
      text: WuiBinding<WuiStr>(text),
      prompt: WuiComputed<WuiStyledStr>(prompt),
      env: env
    )
  } else {
    search = nil
  }

  return WuiNavigationBarState(
    title: title,
    subtitle: subtitle,
    toolbar: toolbar,
    search: search,
    color: color,
    hidden: hidden
  )
}

@MainActor
private func makeNavigationTitle(from titlePtr: OpaquePointer, env: WuiEnvironment)
  -> WuiNavigationTitle
{
  let titleView = WuiAnyView(anyview: titlePtr, env: env)
  let (text, isPlainText) = extractNavigationTitleText(from: titleView)
  return WuiNavigationTitle(view: titleView, text: text, isPlainText: isPlainText)
}

@MainActor
func extractNavigationTitleText(from titleView: PlatformView) -> (String?, Bool) {
  #if canImport(UIKit)
    func findText(in view: UIView) -> String? {
      if let label = view as? UILabel {
        return label.attributedText?.string ?? label.text
      }
      for sub in view.subviews {
        if let t = findText(in: sub) { return t }
      }
      return nil
    }
    if let text = findText(in: titleView) {
      return (text, true)
    }
  #elseif canImport(AppKit)
    func findText(in view: NSView) -> String? {
      if let field = view as? NSTextField {
        let plain = field.stringValue
        if !plain.isEmpty { return plain }
        let attributed = field.attributedStringValue.string
        return attributed.isEmpty ? nil : attributed
      }
      for sub in view.subviews {
        if let t = findText(in: sub) { return t }
      }
      return nil
    }
    if let text = findText(in: titleView) {
      return (text, true)
    }
  #endif

  return (nil, false)
}
