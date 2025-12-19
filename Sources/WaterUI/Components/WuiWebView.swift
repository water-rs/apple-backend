// WuiWebView.swift
// WebView component - WKWebView wrapper for WaterUI
//
// # Layout Behavior
// WebView is greedy - it expands to fill all available space.

import CWaterUI
import WebKit
import os

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private let logger = Logger(subsystem: "dev.waterui", category: "WuiWebView")

// MARK: - WebView Wrapper

/// Wraps a WKWebView and implements FFI function pointers for Rust integration.
@MainActor
final class WebViewWrapper: NSObject {
    let webView: WKWebView
    private var eventCallback: CWaterUI.WuiFn_WuiWebViewEvent?
    private var userScripts: [(String, CWaterUI.WuiScriptInjectionTime)] = []

    override init() {
        let config = WKWebViewConfiguration()
        #if canImport(UIKit)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        #endif

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.navigationDelegate = self
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
            logger.warning("Invalid URL: \(urlString)")
            return
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

    func canGoBack() -> Bool {
        webView.canGoBack
    }

    func canGoForward() -> Bool {
        webView.canGoForward
    }

    // MARK: - Configuration

    func setUserAgent(_ userAgent: String) {
        webView.customUserAgent = userAgent
    }

    func injectScript(_ script: String, time: CWaterUI.WuiScriptInjectionTime) {
        let injectionTime: WKUserScriptInjectionTime = time == WuiScriptInjectionTime_DocumentStart
            ? .atDocumentStart
            : .atDocumentEnd

        let userScript = WKUserScript(
            source: script,
            injectionTime: injectionTime,
            forMainFrameOnly: true
        )
        webView.configuration.userContentController.addUserScript(userScript)
        userScripts.append((script, time))
    }

    // MARK: - Event Watching

    func setEventCallback(_ callback: CWaterUI.WuiFn_WuiWebViewEvent) {
        self.eventCallback = callback
    }

    private func emitEvent(_ event: CWaterUI.WuiWebViewEvent) {
        guard let callback = eventCallback else { return }
        callback.call?(callback.data, event)
    }

    private func emitStateChanged() {
        let event = CWaterUI.WuiWebViewEvent(
            event_type: WuiWebViewEventType_StateChanged,
            url: WuiStr(string: "").intoInner(),
            url2: WuiStr(string: "").intoInner(),
            message: WuiStr(string: "").intoInner(),
            progress: 0,
            can_go_back: webView.canGoBack,
            can_go_forward: webView.canGoForward
        )
        emitEvent(event)
    }

    // MARK: - JavaScript

    func runJavaScript(_ script: String, callback: CWaterUI.WuiJsCallback) {
        webView.evaluateJavaScript(script) { result, error in
            let callbackData = callback.data
            let callbackFn = callback.call

            if let error = error {
                let errorMsg = error.localizedDescription
                let errorStr = WuiStr(string: errorMsg).intoInner()
                callbackFn?(callbackData, false, errorStr)
            } else {
                let resultStr: String
                if let result = result {
                    if let jsonData = try? JSONSerialization.data(withJSONObject: result),
                       let jsonStr = String(data: jsonData, encoding: .utf8) {
                        resultStr = jsonStr
                    } else {
                        resultStr = String(describing: result)
                    }
                } else {
                    resultStr = "null"
                }
                let wuiStr = WuiStr(string: resultStr).intoInner()
                callbackFn?(callbackData, true, wuiStr)
            }
        }
    }

    // MARK: - FFI Handle Creation

    func toFFIHandle() -> CWaterUI.WuiWebViewHandle {
        let ptr = Unmanaged.passRetained(self).toOpaque()

        return CWaterUI.WuiWebViewHandle(
            data: ptr,
            go_back: { rawPtr in
                guard let rawPtr = rawPtr else { return }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                Task { @MainActor in wrapper.goBack() }
            },
            go_forward: { rawPtr in
                guard let rawPtr = rawPtr else { return }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                Task { @MainActor in wrapper.goForward() }
            },
            go_to: { rawPtr, url in
                guard let rawPtr = rawPtr else { return }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                let urlString = WuiStr(url).toString()
                Task { @MainActor in wrapper.goTo(urlString) }
            },
            stop: { rawPtr in
                guard let rawPtr = rawPtr else { return }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                Task { @MainActor in wrapper.stop() }
            },
            refresh: { rawPtr in
                guard let rawPtr = rawPtr else { return }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                Task { @MainActor in wrapper.refresh() }
            },
            can_go_back: { rawPtr in
                guard let rawPtr = rawPtr else { return false }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                // Note: This is called from any thread, but canGoBack is thread-safe to read
                return wrapper.webView.canGoBack
            },
            can_go_forward: { rawPtr in
                guard let rawPtr = rawPtr else { return false }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                return wrapper.webView.canGoForward
            },
            set_user_agent: { rawPtr, userAgent in
                guard let rawPtr = rawPtr else { return }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                let uaString = WuiStr(userAgent).toString()
                Task { @MainActor in wrapper.setUserAgent(uaString) }
            },
            inject_script: { rawPtr, script, time in
                guard let rawPtr = rawPtr else { return }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                let scriptString = WuiStr(script).toString()
                Task { @MainActor in wrapper.injectScript(scriptString, time: time) }
            },
            watch: { rawPtr, callback in
                guard let rawPtr = rawPtr else { return }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                Task { @MainActor in wrapper.setEventCallback(callback) }
            },
            run_javascript: { rawPtr, script, callback in
                guard let rawPtr = rawPtr else { return }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                let scriptString = WuiStr(script).toString()
                Task { @MainActor in wrapper.runJavaScript(scriptString, callback: callback) }
            },
            drop: { rawPtr in
                guard let rawPtr = rawPtr else { return }
                // Release the retained reference
                Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).release()
            }
        )
    }
}

// MARK: - WKNavigationDelegate

extension WebViewWrapper: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            let urlStr = webView.url?.absoluteString ?? ""
            let event = CWaterUI.WuiWebViewEvent(
                event_type: WuiWebViewEventType_WillNavigate,
                url: WuiStr(string: urlStr).intoInner(),
                url2: WuiStr(string: "").intoInner(),
                message: WuiStr(string: "").intoInner(),
                progress: 0,
                can_go_back: false,
                can_go_forward: false
            )
            emitEvent(event)
            emitStateChanged()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let event = CWaterUI.WuiWebViewEvent(
                event_type: WuiWebViewEventType_Loaded,
                url: WuiStr(string: "").intoInner(),
                url2: WuiStr(string: "").intoInner(),
                message: WuiStr(string: "").intoInner(),
                progress: 1.0,
                can_go_back: false,
                can_go_forward: false
            )
            emitEvent(event)
            emitStateChanged()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            let event = CWaterUI.WuiWebViewEvent(
                event_type: WuiWebViewEventType_Error,
                url: WuiStr(string: "").intoInner(),
                url2: WuiStr(string: "").intoInner(),
                message: WuiStr(string: error.localizedDescription).intoInner(),
                progress: 0,
                can_go_back: false,
                can_go_forward: false
            )
            emitEvent(event)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            let event = CWaterUI.WuiWebViewEvent(
                event_type: WuiWebViewEventType_Error,
                url: WuiStr(string: "").intoInner(),
                url2: WuiStr(string: "").intoInner(),
                message: WuiStr(string: error.localizedDescription).intoInner(),
                progress: 0,
                can_go_back: false,
                can_go_forward: false
            )
            emitEvent(event)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            // Note: We don't have access to the original URL here easily
            // The redirect event is emitted with the new URL
            let urlStr = webView.url?.absoluteString ?? ""
            let event = CWaterUI.WuiWebViewEvent(
                event_type: WuiWebViewEventType_Redirect,
                url: WuiStr(string: "").intoInner(),  // from URL not available
                url2: WuiStr(string: urlStr).intoInner(),  // to URL
                message: WuiStr(string: "").intoInner(),
                progress: 0,
                can_go_back: false,
                can_go_forward: false
            )
            emitEvent(event)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Handle SSL certificate challenges
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            // For development, you might want to accept all certificates
            // In production, you should validate properly
            if let serverTrust = challenge.protectionSpace.serverTrust {
                let credential = URLCredential(trust: serverTrust)
                Task { @MainActor in
                    completionHandler(.useCredential, credential)
                }
                return
            }
        }
        Task { @MainActor in
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Controller Installation

/// Installs the WebView controller into the environment.
/// Call this during app initialization before waterui_app().
@MainActor
public func installWebViewController(env: OpaquePointer?) {
    let createFn: @convention(c) () -> CWaterUI.WuiWebViewHandle = {
        // This runs on whatever thread Rust calls it from
        // We need to dispatch to main actor
        var result: CWaterUI.WuiWebViewHandle?
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            let wrapper = WebViewWrapper()
            result = wrapper.toFFIHandle()
            semaphore.signal()
        }

        semaphore.wait()
        return result!
    }
    waterui_env_install_webview_controller(env, createFn)
}
