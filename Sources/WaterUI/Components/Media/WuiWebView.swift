// WuiWebView.swift
// WebView component - WKWebView wrapper for WaterUI
//
// # Layout Behavior
// WebView is greedy - it expands to fill all available space.

import CWaterUI
import OSLog
import Security
import WebKit

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

// MARK: - WebView Wrapper

/// Wraps a WKWebView and implements FFI function pointers for Rust integration.
@MainActor
final class WebViewWrapper: NSObject, WKScriptMessageHandler {
  let webView: WKWebView
  private var eventCallback: CWaterUI.WuiFn_WuiWebViewEvent?
  private var redirectsEnabled = true
  private var redirectsObservation: WuiComputedObservation<Bool>?
  private var lastNavigationUrl: String?
  private var progressObservation: NSKeyValueObservation?
  private var messageHandlers: [String: CWaterUI.WuiFn_WuiWebViewMessage] = [:]
  private var installedBridge = false
  /// URI patterns whose documents may reach the bridge, or nil for every origin.
  private var bridgeOriginPatterns: [String]?

  override init() {
    let config = WKWebViewConfiguration()
    #if canImport(UIKit)
      config.allowsInlineMediaPlayback = true
      config.mediaTypesRequiringUserActionForPlayback = []
    #endif

    webView = WKWebView(frame: .zero, configuration: config)
    super.init()

    webView.navigationDelegate = self
    webView.uiDelegate = self

    progressObservation = webView.observe(\.estimatedProgress, options: [.new]) {
      [weak self] _, change in
      guard let self else { return }
      let progress = Float(change.newValue ?? 0.0)
      Task { @MainActor in
        self.emitLoading(progress)
      }
    }
  }

  nonisolated private static func withHandle<Result: Sendable>(
    _ rawPtr: UnsafeRawPointer?,
    operation: StaticString,
    _ body: @MainActor (WebViewWrapper) -> Result
  ) -> Result {
    precondition(Thread.isMainThread, "WebView \(operation) must run on its owning UI thread")
    guard let rawPtr else {
      fatalError("WebView \(operation) received a null handle")
    }
    let address = UInt(bitPattern: rawPtr)
    return MainActor.assumeIsolated {
      let rawPtr = UnsafeRawPointer(bitPattern: address)!
      return body(Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue())
    }
  }

  /// Installs the shared bridge and the single message handler it transports over.
  ///
  /// The script comes from Rust so the envelope format is defined in exactly one
  /// place; Swift only routes messages to the handler table it owns.
  private func ensureBridgeInstalled() {
    guard !installedBridge else { return }
    installedBridge = true
    // Transport first: the shared script calls `__wateruiSend`.
    injectScript(Self.transportScript, time: WuiScriptInjectionTime_DocumentStart)
    injectScript(
      WuiStr(waterui_webview_bridge_script()).toString(),
      time: WuiScriptInjectionTime_DocumentStart
    )
    webView.configuration.userContentController.add(self, name: Self.sendFunction)
  }

  private static let sendFunction = "__wateruiSend"
  private static let transportScript = """
    globalThis.__wateruiSend = function (envelope) { \
    window.webkit.messageHandlers.\(sendFunction).postMessage(envelope); };
    """

  private final class MessageReplyContext {
    weak var wrapper: WebViewWrapper?
    let requestId: UInt64

    init(wrapper: WebViewWrapper, requestId: UInt64) {
      self.wrapper = wrapper
      self.requestId = requestId
    }
  }


  private static let messageReplyCallback:
    @convention(c) (
      UnsafeMutableRawPointer?,
      Bool,
      CWaterUI.WuiJsReplyKind,
      CWaterUI.WuiStr
    ) -> Void = { data, success, kind, result in
      guard let data else {
        fatalError("WebView message reply received null callback data")
      }
      let ctx = Unmanaged<MessageReplyContext>.fromOpaque(data).takeRetainedValue()
      guard let wrapper = ctx.wrapper else {
        fatalError("WebView message reply outlived its WebView")
      }

      // Rust renders the reply so the envelope format is not restated here.
      // `kind` is carried through untouched: whether the page receives a value
      // or a Uint8Array is the handler's decision, not this transport's.
      let js = WuiStr(
        waterui_webview_bridge_reply_script(ctx.requestId, success, kind, result)
      ).toString()
      precondition(Thread.isMainThread, "WebView message replies must run on the UI thread")
      MainActor.assumeIsolated {
        wrapper.webView.evaluateJavaScript(js) { _, error in
          if let error {
            fatalError("WebView failed to deliver a JavaScript bridge reply: \(error)")
          }
        }
      }
    }

  /// Registering a name twice replaces the handler; one transport serves them all.
  func addHandler(_ name: String, callback: CWaterUI.WuiFn_WuiWebViewMessage) {
    if let existing = messageHandlers[name] {
      guard let drop = existing.drop else {
        fatalError("WebView message handler has no drop function")
      }
      drop(existing.data)
    }
    messageHandlers[name] = callback
    ensureBridgeInstalled()
  }

  /// Restricts which documents may reach the bridge.
  ///
  /// A handler is a capability, so a page the view navigates to is not entitled
  /// to the handlers the application registered.
  func setBridgeOrigins(_ patterns: String) {
    bridgeOriginPatterns = patterns == "*" ? nil : patterns.split(separator: "\n").map(String.init)
  }

  /// Whether a message from `frame` may be dispatched.
  ///
  /// WebKit reports the frame, so the origin is authenticated by the engine
  /// rather than claimed by the page.
  private func frameMayUseBridge(_ frame: WKFrameInfo) -> Bool {
    guard frame.isMainFrame else { return false }
    guard let patterns = bridgeOriginPatterns else { return true }
    let origin = frame.securityOrigin
    var candidate = "\(origin.protocol)://\(origin.host)"
    if origin.port != 0 {
      candidate += ":\(origin.port)"
    }
    return patterns.contains { $0 == candidate + "/*" || $0 == candidate }
  }

  /// Removing a name that was never registered is a no-op.
  func removeHandler(_ name: String) {
    if let existing = messageHandlers.removeValue(forKey: name) {
      guard let drop = existing.drop else {
        fatalError("WebView message handler has no drop function")
      }
      drop(existing.data)
    }
  }

  nonisolated func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    Task { @MainActor [weak self] in
      self?.handleScriptMessage(name: message.name, body: message.body, frame: message.frameInfo)
    }
  }

  /// Routes one `waterui.invoke(...)` envelope to the handler it names.
  ///
  /// Page script reaches this transport directly, so a malformed envelope or an
  /// unknown handler name is rejected back to JavaScript rather than being fatal.
  @MainActor
  private func handleScriptMessage(name: String, body: Any, frame: WKFrameInfo) {
    guard frameMayUseBridge(frame) else {
      Logger.waterui.warning(
        "a document outside the bridge origin policy tried to call a WaterUI handler")
      return
    }
    guard let envelope = body as? String else {
      Logger.waterui.warning("WaterUI bridge received a non-string message body")
      return
    }

    let request = waterui_webview_parse_bridge_request(WuiStr(string: envelope).intoInner())
    let handlerName = WuiStr(request.name).toString()
    let payloadB64 = WuiStr(request.payload_base64).toString()
    guard request.ok else { return }

    guard let callback = messageHandlers[handlerName], let call = callback.call else {
      Logger.waterui.warning(
        "page script called WaterUI handler '\(handlerName)', which is not registered")
      let js = WuiStr(
        waterui_webview_bridge_reply_script(
          request.id,
          false,
          WuiJsReplyKind(0),
          WuiStr(string: "no WaterUI handler named '\(handlerName)'").intoInner()
        )
      ).toString()
      webView.evaluateJavaScript(js, completionHandler: nil)
      return
    }

    let replyCtx = Unmanaged.passRetained(
      MessageReplyContext(wrapper: self, requestId: request.id)
    ).toOpaque()
    let msg = CWaterUI.WuiWebViewMessage(
      payload_base64: WuiStr(string: payloadB64).intoInner(),
      reply: CWaterUI.WuiWebViewReply(data: replyCtx, call: Self.messageReplyCallback)
    )
    call(callback.data, msg)
  }

  @MainActor
  private func cleanupForDrop() {
    // Break retain cycles: WKUserContentController strongly retains its message handlers.
    let controller = webView.configuration.userContentController
    if installedBridge {
      controller.removeScriptMessageHandler(forName: Self.sendFunction)
    }
    for (_, cb) in messageHandlers {
      guard let drop = cb.drop else {
        fatalError("WebView message handler has no drop function")
      }
      drop(cb.data)
    }
    messageHandlers.removeAll()

    if let cb = eventCallback {
      guard let drop = cb.drop else {
        fatalError("WebView event callback has no drop function")
      }
      drop(cb.data)
      eventCallback = nil
    }

    progressObservation?.invalidate()
    progressObservation = nil
    redirectsObservation = nil

    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil

    controller.removeAllUserScripts()
    installedBridge = false
  }

  func setCookie(_ setCookieHeaderValue: String) {
    let trimmed = setCookieHeaderValue.trimmingCharacters(in: .whitespacesAndNewlines)
    precondition(!trimmed.isEmpty, "WebView cannot set an empty cookie")

    let url = webView.url ?? Self.cookieOrigin(from: trimmed)
    let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": trimmed], for: url)
    guard !cookies.isEmpty else {
      fatalError("WebView received an invalid Set-Cookie value: \(trimmed)")
    }

    let store = webView.configuration.websiteDataStore.httpCookieStore
    for cookie in cookies {
      store.setCookie(cookie, completionHandler: nil)
    }
  }

  private static func cookieOrigin(from setCookieValue: String) -> URL {
    let attributes = setCookieValue.split(separator: ";").dropFirst()
    let domain = attributes.lazy.compactMap { attribute -> String? in
      let parts = attribute.split(separator: "=", maxSplits: 1)
      guard parts.count == 2 else { return nil }
      let name = parts[0].trimmingCharacters(in: .whitespaces)
      guard name.caseInsensitiveCompare("Domain") == .orderedSame else { return nil }
      return parts[1].trimmingCharacters(in: .whitespaces)
    }.first
    guard let domain, !domain.isEmpty else {
      fatalError("A cookie set before navigation requires a Domain attribute")
    }
    var components = URLComponents()
    components.scheme =
      attributes.contains(where: {
        $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Secure") == .orderedSame
      }) ? "https" : "http"
    components.host = String(domain.drop(while: { $0 == "." }))
    components.path = "/"
    guard let url = components.url else {
      fatalError("WebView cookie has an invalid Domain attribute: \(domain)")
    }
    return url
  }

  private static func serializeCookies(_ cookies: [HTTPCookie]) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    let lines = cookies.map { cookie in
      var parts: [String] = ["\(cookie.name)=\(cookie.value)"]
      parts.append("Domain=\(cookie.domain)")
      parts.append("Path=\(cookie.path)")
      if let expires = cookie.expiresDate {
        parts.append("Expires=\(formatter.string(from: expires))")
      }
      if cookie.isSecure { parts.append("Secure") }
      if cookie.isHTTPOnly { parts.append("HttpOnly") }
      if let policy = cookie.sameSitePolicy {
        // Foundation names Lax and Strict; anything else is a policy WebKit
        // understands and we do not, which is a reason to pass it through
        // rather than to drop it.
        switch policy {
        case .sameSiteLax: parts.append("SameSite=Lax")
        case .sameSiteStrict: parts.append("SameSite=Strict")
        default: parts.append("SameSite=\(policy.rawValue)")
        }
      }
      return parts.joined(separator: "; ")
    }
    return lines.joined(separator: "\n")
  }

  // MARK: - Navigation

  func goBack() {
    webView.goBack()
  }

  func goForward() {
    webView.goForward()
  }

  func goTo(_ urlString: String) {
    guard let url = URL(string: urlString) else {
      fatalError("WebView received an invalid URL: \(urlString)")
    }
    webView.load(URLRequest(url: url))
  }

  func stop() {
    webView.stopLoading()
  }

  func refresh() {
    webView.reload()
  }

  // MARK: - State

  // MARK: - Configuration

  func setUserAgent(_ userAgent: String) {
    let trimmed = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
    webView.customUserAgent = trimmed.isEmpty ? nil : trimmed
  }

  func setRedirectsEnabled(_ enabled: WuiComputed<Bool>) {
    let observation = WuiComputedObservation(enabled) { [weak self] enabled, _ in
      self?.redirectsEnabled = enabled
    }
    redirectsEnabled = observation.value
    redirectsObservation = observation
  }

  func injectScript(_ script: String, time: CWaterUI.WuiScriptInjectionTime) {
    let injectionTime: WKUserScriptInjectionTime =
      time == WuiScriptInjectionTime_DocumentStart
      ? .atDocumentStart
      : .atDocumentEnd

    let userScript = WKUserScript(
      source: script,
      injectionTime: injectionTime,
      forMainFrameOnly: true
    )
    webView.configuration.userContentController.addUserScript(userScript)
  }

  // MARK: - Event Watching

  func setEventCallback(_ callback: CWaterUI.WuiFn_WuiWebViewEvent) {
    if let old = eventCallback {
      guard let drop = old.drop else {
        fatalError("WebView event callback has no drop function")
      }
      drop(old.data)
    }
    self.eventCallback = callback
  }

  private func emitEvent(_ makeEvent: () -> CWaterUI.WuiWebViewEvent) {
    guard let callback = eventCallback else { return }
    guard let call = callback.call else {
      fatalError("WebView event callback has no call function")
    }
    call(callback.data, makeEvent())
  }

  private func emitLoading(_ progress: Float) {
    emitEvent {
      CWaterUI.WuiWebViewEvent(
        event_type: WuiWebViewEventType_Loading,
        url: nil,
        url2: nil,
        message: nil,
        progress: progress,
        can_go_back: false,
        can_go_forward: false
      )
    }
  }

  private func emitStateChanged() {
    emitEvent {
      CWaterUI.WuiWebViewEvent(
        event_type: WuiWebViewEventType_StateChanged,
        url: nil,
        url2: nil,
        message: nil,
        progress: 0,
        can_go_back: webView.canGoBack,
        can_go_forward: webView.canGoForward
      )
    }
  }

  private func emitSslError(_ urlString: String, message: String) {
    emitEvent {
      CWaterUI.WuiWebViewEvent(
        event_type: WuiWebViewEventType_SslError,
        url: WuiStr(string: urlString).intoRustOwnedPointer(),
        url2: nil,
        message: WuiStr(string: message).intoRustOwnedPointer(),
        progress: 0,
        can_go_back: false,
        can_go_forward: false
      )
    }
  }

  private func emitWillNavigate(_ urlString: String, allowRepeat: Bool) {
    guard !urlString.isEmpty else { return }
    if !allowRepeat, lastNavigationUrl == urlString {
      return
    }
    lastNavigationUrl = urlString
    emitEvent {
      CWaterUI.WuiWebViewEvent(
        event_type: WuiWebViewEventType_WillNavigate,
        url: WuiStr(string: urlString).intoRustOwnedPointer(),
        url2: nil,
        message: nil,
        progress: 0,
        can_go_back: false,
        can_go_forward: false
      )
    }
  }

  // MARK: - JavaScript

  func runJavaScript(_ script: String, callback: CWaterUI.WuiJsCallback) {
    guard let callbackFn = callback.call else {
      fatalError("WebView JavaScript execution requires a completion callback")
    }
    webView.evaluateJavaScript(script) { result, error in
      let callbackData = callback.data

      if let error = error {
        let errorMsg = error.localizedDescription
        let errorStr = WuiStr(string: errorMsg).intoInner()
        callbackFn(callbackData, false, errorStr)
      } else {
        let resultStr: String
        if let result = result {
          // JSONSerialization raises NSException on invalid objects, so validate first.
          if JSONSerialization.isValidJSONObject(result) {
            do {
              let jsonData = try JSONSerialization.data(withJSONObject: result)
              guard let json = String(data: jsonData, encoding: .utf8) else {
                fatalError("WebView JavaScript result serialization produced non-UTF-8 data")
              }
              resultStr = json
            } catch {
              fatalError("WebView failed to serialize a valid JavaScript result: \(error)")
            }
          } else {
            resultStr = String(describing: result)
          }
        } else {
          resultStr = "null"
        }
        let wuiStr = WuiStr(string: resultStr).intoInner()
        callbackFn(callbackData, true, wuiStr)
      }
    }
  }

  // MARK: - FFI Handle Creation

  func toFFIHandle() -> CWaterUI.WuiWebViewHandle {
    let ptr = Unmanaged.passRetained(self).toOpaque()

    return CWaterUI.WuiWebViewHandle(
      data: ptr,
      go_back: { rawPtr in
        WebViewWrapper.withHandle(rawPtr, operation: "go_back") { $0.goBack() }
      },
      go_forward: { rawPtr in
        WebViewWrapper.withHandle(rawPtr, operation: "go_forward") { $0.goForward() }
      },
      go_to: { rawPtr, url in
        WebViewWrapper.withHandle(rawPtr, operation: "go_to") { wrapper in
          wrapper.goTo(WuiStr(url).toString())
        }
      },
      stop: { rawPtr in
        WebViewWrapper.withHandle(rawPtr, operation: "stop") { $0.stop() }
      },
      refresh: { rawPtr in
        WebViewWrapper.withHandle(rawPtr, operation: "refresh") { $0.refresh() }
      },
      can_go_back: { rawPtr in
        WebViewWrapper.withHandle(rawPtr, operation: "can_go_back") {
          $0.webView.canGoBack
        }
      },
      can_go_forward: { rawPtr in
        WebViewWrapper.withHandle(rawPtr, operation: "can_go_forward") {
          $0.webView.canGoForward
        }
      },
      set_user_agent: { rawPtr, userAgent in
        WebViewWrapper.withHandle(rawPtr, operation: "set_user_agent") { wrapper in
          wrapper.setUserAgent(WuiStr(userAgent).toString())
        }
      },
      set_redirects_enabled: { rawPtr, enabledPtr in
        guard let enabledPtr else {
          fatalError("WebView set_redirects_enabled received a null signal")
        }
        WebViewWrapper.withHandle(rawPtr, operation: "set_redirects_enabled") { wrapper in
          wrapper.setRedirectsEnabled(WuiComputed<Bool>(enabledPtr))
        }
      },
      inject_script: { rawPtr, script, time in
        WebViewWrapper.withHandle(rawPtr, operation: "inject_script") { wrapper in
          wrapper.injectScript(WuiStr(script).toString(), time: time)
        }
      },
      watch: { rawPtr, callback in
        WebViewWrapper.withHandle(rawPtr, operation: "watch") { wrapper in
          wrapper.setEventCallback(callback)
        }
      },
      add_handler: { rawPtr, name, callback in
        WebViewWrapper.withHandle(rawPtr, operation: "add_handler") { wrapper in
          wrapper.addHandler(WuiStr(name).toString(), callback: callback)
        }
      },
      remove_handler: { rawPtr, name in
        WebViewWrapper.withHandle(rawPtr, operation: "remove_handler") { wrapper in
          wrapper.removeHandler(WuiStr(name).toString())
        }
      },
      set_bridge_origins: { rawPtr, patterns in
        WebViewWrapper.withHandle(rawPtr, operation: "set_bridge_origins") { wrapper in
          wrapper.setBridgeOrigins(WuiStr(patterns).toString())
        }
      },
      set_cookie: { rawPtr, cookie in
        WebViewWrapper.withHandle(rawPtr, operation: "set_cookie") { wrapper in
          wrapper.setCookie(WuiStr(cookie).toString())
        }
      },
      get_cookies: { rawPtr, callback in
        guard let call = callback.call else {
          fatalError("waterui_webview.get_cookies received a null completion callback")
        }
        WebViewWrapper.withHandle(rawPtr, operation: "get_cookies") { wrapper in
          let store = wrapper.webView.configuration.websiteDataStore.httpCookieStore
          store.getAllCookies { cookies in
            let result = WuiStr(
              string: WebViewWrapper.serializeCookies(cookies)
            ).intoInner()
            call(callback.data, result)
          }
        }
      },
      run_javascript: { rawPtr, script, callback in
        WebViewWrapper.withHandle(rawPtr, operation: "run_javascript") { wrapper in
          wrapper.runJavaScript(WuiStr(script).toString(), callback: callback)
        }
      },
      drop: { rawPtr in
        precondition(Thread.isMainThread, "WebView drop must run on its owning UI thread")
        guard let rawPtr else {
          fatalError("WebView drop received a null handle")
        }
        MainActor.assumeIsolated {
          let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeRetainedValue()
          wrapper.cleanupForDrop()
        }
      }
    )
  }

  @MainActor deinit {
    precondition(
      messageHandlers.isEmpty && eventCallback == nil,
      "WebView was deinitialized before its FFI handle was dropped"
    )
  }
}

// MARK: - WKNavigationDelegate

extension WebViewWrapper: WKNavigationDelegate {
  nonisolated func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    Task { @MainActor in
      let requestUrl = navigationAction.request.url?.absoluteString ?? ""
      let allowRepeat =
        navigationAction.navigationType == .reload
        || navigationAction.navigationType == .backForward
        || navigationAction.navigationType == .formSubmitted
        || navigationAction.navigationType == .formResubmitted

      if navigationAction.targetFrame == nil {
        emitWillNavigate(requestUrl, allowRepeat: allowRepeat)
        webView.load(navigationAction.request)
        decisionHandler(.cancel)
        return
      }

      if navigationAction.targetFrame?.isMainFrame ?? true {
        emitWillNavigate(requestUrl, allowRepeat: allowRepeat)
      }
      decisionHandler(.allow)
    }
  }

  nonisolated func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
  ) {
    Task { @MainActor in
      guard navigationResponse.isForMainFrame else {
        decisionHandler(.allow)
        return
      }
      guard let response = navigationResponse.response as? HTTPURLResponse else {
        decisionHandler(.allow)
        return
      }

      let statusCode = response.statusCode
      guard (300..<400).contains(statusCode) else {
        decisionHandler(.allow)
        return
      }

      if !redirectsEnabled {
        let fromUrl = response.url?.absoluteString ?? ""
        let location =
          response.allHeaderFields.first { key, _ in
            (key as? String)?.caseInsensitiveCompare("location") == .orderedSame
          }?.value as? String ?? ""
        let toUrl =
          URL(string: location, relativeTo: response.url)?.absoluteString
          ?? location

        emitEvent {
          CWaterUI.WuiWebViewEvent(
            event_type: WuiWebViewEventType_Redirect,
            url: WuiStr(string: fromUrl).intoRustOwnedPointer(),
            url2: WuiStr(string: toUrl).intoRustOwnedPointer(),
            message: nil,
            progress: 0,
            can_go_back: false,
            can_go_forward: false
          )
        }
        webView.stopLoading()
        decisionHandler(.cancel)
        return
      }

      decisionHandler(.allow)
    }
  }

  nonisolated func webView(
    _ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!
  ) {
    Task { @MainActor in
      let urlStr = webView.url?.absoluteString ?? ""
      emitWillNavigate(urlStr, allowRepeat: false)
      emitLoading(0)
      emitStateChanged()
    }
  }

  nonisolated func webView(
    _ webView: WKWebView,
    didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
  ) {
    Task { @MainActor in
      let toUrl = webView.url?.absoluteString ?? ""
      let fromUrl = lastNavigationUrl ?? ""

      if !redirectsEnabled {
        emitEvent {
          CWaterUI.WuiWebViewEvent(
            event_type: WuiWebViewEventType_Redirect,
            url: WuiStr(string: fromUrl).intoRustOwnedPointer(),
            url2: WuiStr(string: toUrl).intoRustOwnedPointer(),
            message: nil,
            progress: 0,
            can_go_back: false,
            can_go_forward: false
          )
        }
        webView.stopLoading()
        return
      }

      // Update navigation URL to the redirected destination
      lastNavigationUrl = toUrl
      emitWillNavigate(toUrl, allowRepeat: true)
    }
  }

  nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    Task { @MainActor in
      emitEvent {
        CWaterUI.WuiWebViewEvent(
          event_type: WuiWebViewEventType_Loaded,
          url: nil,
          url2: nil,
          message: nil,
          progress: 1.0,
          can_go_back: false,
          can_go_forward: false
        )
      }
      emitStateChanged()
    }
  }

  nonisolated func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
  ) {
    Task { @MainActor in
      emitEvent {
        CWaterUI.WuiWebViewEvent(
          event_type: WuiWebViewEventType_Error,
          url: nil,
          url2: nil,
          message: WuiStr(string: error.localizedDescription).intoRustOwnedPointer(),
          progress: 0,
          can_go_back: false,
          can_go_forward: false
        )
      }
    }
  }

  nonisolated func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    Task { @MainActor in
      emitEvent {
        CWaterUI.WuiWebViewEvent(
          event_type: WuiWebViewEventType_Error,
          url: nil,
          url2: nil,
          message: WuiStr(string: error.localizedDescription).intoRustOwnedPointer(),
          progress: 0,
          can_go_back: false,
          can_go_forward: false
        )
      }
    }
  }

  nonisolated func webView(
    _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) ->
      Void
  ) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let serverTrust = challenge.protectionSpace.serverTrust
    {
      var trustError: CFError?
      let ok = SecTrustEvaluateWithError(serverTrust, &trustError)
      if ok {
        let credential = URLCredential(trust: serverTrust)
        Task { @MainActor in completionHandler(.useCredential, credential) }
        return
      }

      let message = (trustError as Error?)?.localizedDescription ?? "SSL certificate error"
      Task { @MainActor in
        let urlStr = webView.url?.absoluteString ?? ""
        emitSslError(urlStr, message: message)
        completionHandler(.cancelAuthenticationChallenge, nil)
      }
      return
    }

    Task { @MainActor in completionHandler(.performDefaultHandling, nil) }
  }
}

// MARK: - WKUIDelegate

extension WebViewWrapper: WKUIDelegate {
  nonisolated func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    Task { @MainActor in
      if navigationAction.targetFrame == nil {
        webView.load(navigationAction.request)
      }
    }
    return nil
  }
}

// MARK: - Controller Installation

/// Installs the WebView controller into the environment.
/// Call this during app initialization before waterui_app().
@MainActor
public func installWebViewController(env: OpaquePointer?) {
  guard let env else {
    fatalError("WebView controller installation requires a WaterUI environment")
  }
  if waterui_env_has_webview_controller(env) {
    return
  }
  struct HandleTransfer: @unchecked Sendable {
    let value: CWaterUI.WuiWebViewHandle
  }
  let createFn: @convention(c) () -> CWaterUI.WuiWebViewHandle = {
    precondition(Thread.isMainThread, "WebView controller must be created on the UI thread")
    return MainActor.assumeIsolated {
      HandleTransfer(value: WebViewWrapper().toFFIHandle())
    }.value
  }
  waterui_env_install_webview_controller(env, createFn)
}

// MARK: - WebView Component for Rendering

/// Native component that renders a WebView in the view hierarchy.
@MainActor
final class WuiWebViewComponent: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_webview_id() }

  private(set) var stretchAxis: WuiStretchAxis = .both
  private let webViewWrapper: WebViewWrapper
  private let webViewPtr: OpaquePointer

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    guard let webViewPtr = waterui_force_as_webview(anyview) else {
      fatalError("WuiWebViewComponent received an invalid WebView")
    }
    guard let handlePtr = waterui_webview_native_handle(webViewPtr) else {
      fatalError("WuiWebViewComponent received a WebView without a native handle")
    }
    let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(handlePtr).takeUnretainedValue()
    self.webViewPtr = webViewPtr
    self.webViewWrapper = wrapper
    super.init(frame: .zero)

    // Add the WKWebView as a subview
    let webView = wrapper.webView
    webView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(webView)

    NSLayoutConstraint.activate([
      webView.leadingAnchor.constraint(equalTo: leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: trailingAnchor),
      webView.topAnchor.constraint(equalTo: topAnchor),
      webView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @MainActor deinit {
    waterui_drop_web_view(webViewPtr)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    // WebView is greedy - it takes all available space
    let width = proposal.width.map { CGFloat($0) } ?? 320
    let height = proposal.height.map { CGFloat($0) } ?? 480
    return CGSize(width: width, height: height)
  }
}
