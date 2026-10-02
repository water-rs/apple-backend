import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@_extern(c, "waterui_apple_runtime_create")
private func runtimeCreate(
  _ context: UnsafeMutableRawPointer,
  _ ready: @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Void
)
@_extern(c, "waterui_apple_runtime_drop")
private func runtimeDrop(_ runtime: UnsafeMutableRawPointer)
@_extern(c, "waterui_apple_mount")
private func mountCreate(
  _ runtime: UnsafeRawPointer, _ host: UnsafeMutableRawPointer,
  _ assets: UnsafePointer<CChar>, _ fonts: UnsafePointer<CChar>
) -> UnsafeMutableRawPointer
@_extern(c, "waterui_apple_mount_drop")
private func mountDrop(_ mount: UnsafeMutableRawPointer)

/// Resources supplied by the native application or the embedding package.
public struct WaterUIResourceContext: Sendable {
  public let assets: URL
  public let fonts: URL

  public init(assets: URL, fonts: URL) {
    precondition(assets.isFileURL && fonts.isFileURL, "WaterUI resources require file URLs")
    self.assets = assets
    self.fonts = fonts
  }

  public static var application: Self {
    guard let root = Bundle.main.resourceURL else {
      fatalError("The host application has no resource directory")
    }
    return Self(assets: root.appendingPathComponent("waterui_assets"),
                fonts: root.appendingPathComponent("fonts"))
  }
}

/// The process runtime, explicitly shared by every embedded WaterUI instance.
@MainActor
public final class WaterUIRuntime {
  fileprivate let pointer: UnsafeMutableRawPointer

  private init(_ pointer: UnsafeMutableRawPointer) { self.pointer = pointer }

  /// Call once per process, then pass the result to each host controller.
  public static func create() async -> WaterUIRuntime {
    await withCheckedContinuation { continuation in
      let pending = PendingRuntime(continuation)
      runtimeCreate(Unmanaged.passRetained(pending).toOpaque()) { context, runtime in
        MainActor.assumeIsolated {
          let pending = Unmanaged<PendingRuntime>.fromOpaque(context).takeRetainedValue()
          pending.continuation.resume(returning: WaterUIRuntime(runtime))
        }
      }
    }
  }

  @MainActor deinit { runtimeDrop(pointer) }
}

@MainActor
private final class PendingRuntime {
  let continuation: CheckedContinuation<WaterUIRuntime, Never>
  init(_ continuation: CheckedContinuation<WaterUIRuntime, Never>) {
    self.continuation = continuation
  }
}

@MainActor
private final class WaterUIMount {
  private let runtime: WaterUIRuntime
  private let pointer: UnsafeMutableRawPointer

  init(runtime: WaterUIRuntime, host: AnyObject, resources: WaterUIResourceContext) {
    self.runtime = runtime
    self.pointer = resources.assets.path.withCString { assets in
      resources.fonts.path.withCString { fonts in
        mountCreate(UnsafeRawPointer(runtime.pointer), Unmanaged.passUnretained(host).toOpaque(), assets, fonts)
      }
    }
  }

  @MainActor deinit { mountDrop(pointer) }
}

#if canImport(UIKit)
@MainActor
public final class WaterUIHostController: UIViewController {
  private let runtime: WaterUIRuntime
  private let resources: WaterUIResourceContext
  private var mount: WaterUIMount?

  public init(runtime: WaterUIRuntime, resources: WaterUIResourceContext = .application) {
    self.runtime = runtime
    self.resources = resources
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init(runtime:resources:)") }

  public override func loadView() { view = UIView(frame: .zero) }
  public override func viewDidLoad() {
    super.viewDidLoad()
    mount = WaterUIMount(runtime: runtime, host: view, resources: resources)
  }
}

public struct WaterUIHost: UIViewControllerRepresentable {
  public let runtime: WaterUIRuntime
  public let resources: WaterUIResourceContext
  public init(runtime: WaterUIRuntime, resources: WaterUIResourceContext = .application) {
    self.runtime = runtime
    self.resources = resources
  }
  public func makeUIViewController(context: Context) -> WaterUIHostController {
    WaterUIHostController(runtime: runtime, resources: resources)
  }
  public func updateUIViewController(_ controller: WaterUIHostController, context: Context) {}
}
#else
@MainActor
public final class WaterUIHostController: NSViewController {
  private let runtime: WaterUIRuntime
  private let resources: WaterUIResourceContext
  private var mount: WaterUIMount?

  public init(runtime: WaterUIRuntime, resources: WaterUIResourceContext = .application) {
    self.runtime = runtime
    self.resources = resources
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init(runtime:resources:)") }

  public override func loadView() { view = NSView(frame: .zero) }
  public override func viewDidLoad() {
    super.viewDidLoad()
    mount = WaterUIMount(runtime: runtime, host: view, resources: resources)
  }
}

public struct WaterUIHost: NSViewControllerRepresentable {
  public let runtime: WaterUIRuntime
  public let resources: WaterUIResourceContext
  public init(runtime: WaterUIRuntime, resources: WaterUIResourceContext = .application) {
    self.runtime = runtime
    self.resources = resources
  }
  public func makeNSViewController(context: Context) -> WaterUIHostController {
    WaterUIHostController(runtime: runtime, resources: resources)
  }
  public func updateNSViewController(_ controller: WaterUIHostController, context: Context) {}
}
#endif
