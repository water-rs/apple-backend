@MainActor
final class WuiSignalSubscription<T> {
  private final class StoredValue {
    let value: T

    init(_ value: T) {
      self.value = value
    }
  }

  private final class State {
    private var storedValue: StoredValue?
    private var isActive = false
    private let disposeValue: (T) -> Void
    private let onChange: (T, WuiWatcherMetadata) -> Void

    var value: T {
      guard let storedValue else {
        fatalError("WaterUI signal subscription has no current value")
      }
      return storedValue.value
    }

    init(
      disposeValue: @escaping (T) -> Void,
      onChange: @escaping (T, WuiWatcherMetadata) -> Void
    ) {
      self.disposeValue = disposeValue
      self.onChange = onChange
    }

    func receive(_ value: T, metadata: WuiWatcherMetadata) {
      replace(with: value)
      if isActive {
        onChange(value, metadata)
      }
    }

    func finishSubscription(readInitial: () -> T) {
      if storedValue == nil {
        storedValue = StoredValue(readInitial())
      }
      isActive = true
    }

    private func replace(with value: T) {
      if let storedValue {
        disposeValue(storedValue.value)
      }
      storedValue = StoredValue(value)
    }

    @MainActor deinit {
      if let storedValue {
        disposeValue(storedValue.value)
      }
    }
  }

  private let state: State
  private var watcher: WatcherGuard?

  var value: T { state.value }

  init(
    read: () -> T,
    subscribe: (@escaping (T, WuiWatcherMetadata) -> Void) -> WatcherGuard,
    disposeValue: @escaping (T) -> Void = { _ in },
    onChange: @escaping (T, WuiWatcherMetadata) -> Void
  ) {
    let state = State(disposeValue: disposeValue, onChange: onChange)
    let watcher = subscribe { value, metadata in
      state.receive(value, metadata: metadata)
    }
    state.finishSubscription(readInitial: read)
    self.state = state
    self.watcher = watcher
  }

  func cancel() {
    watcher = nil
  }

  @MainActor deinit {
    cancel()
  }
}
