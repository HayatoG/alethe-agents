import AletheModel
import AppKit
import Observation
import WebKit

/// One web pane's page (upstream `WebPane` private browser): a WKWebView on a non-persistent data
/// store, so nothing it visits is kept, and its navigation state for the toolbar. The view is
/// released some time after the pane is hidden (its `WebResourceMode`) or at once under memory
/// pressure, and recreated on the last address when the pane shows again.
@Observable
@MainActor
final class WebPageModel: NSObject {
    private(set) var webView: WKWebView?
    private(set) var url: URL?
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Why the last navigation failed; nil while it works.
    private(set) var failure: String?
    private(set) var options: WebPaneOptions

    /// Called when the page settles on another address, so the pane can persist it.
    @ObservationIgnored var onAddressChange: ((URL) -> Void)?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var eviction: Task<Void, Never>?
    @ObservationIgnored private var isVisible = false

    init(url: URL?, options: WebPaneOptions) {
        self.url = url
        self.options = options
        super.init()
    }

    // MARK: - Visibility and memory

    func show() {
        isVisible = true
        eviction?.cancel()
        eviction = nil
        if webView == nil { makeWebView() }
    }

    func hide(underMemoryPressure: Bool = false) {
        isVisible = false
        eviction?.cancel()
        guard let delay = options.resourceMode.hiddenEvictionDelay(underMemoryPressure: underMemoryPressure) else { return }
        eviction = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.isVisible else { return }
            self.release()
        }
    }

    /// Memory pressure: a hidden page goes now; a visible one stays.
    func relieveMemory() {
        if !isVisible { release() }
    }

    func release() {
        eviction?.cancel()
        eviction = nil
        observations = []
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        isLoading = false
    }

    private func makeWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = options.javascriptEnabled
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.pageZoom = options.zoom
        view.setAccessibilityIdentifier("web.view")
        observations = [
            view.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.title = view.title ?? "" } },
            view.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.isLoading = view.isLoading } },
            view.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            view.observe(\.canGoForward) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
        ]
        webView = view
        if let url { view.load(URLRequest(url: url)) }
    }

    // MARK: - Navigation

    func load(_ url: URL) {
        self.url = url
        failure = nil
        if let webView { webView.load(URLRequest(url: url)) } else if isVisible { makeWebView() }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func reload() {
        failure = nil
        if let webView, webView.url != nil { webView.reload() } else if let url { load(url) }
    }

    func setOptions(_ options: WebPaneOptions) {
        let recreate = options.javascriptEnabled != self.options.javascriptEnabled
        self.options = options
        webView?.pageZoom = options.zoom
        if recreate, webView != nil {
            // JavaScript is fixed when a web view is created.
            release()
            if isVisible { makeWebView() }
        }
    }
}

extension WebPageModel: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        failure = nil
        if let current = webView.url, current != url {
            url = current
            onAddressChange?(current)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        record(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        record(error)
    }

    private func record(_ error: any Error) {
        // A navigation replaced by another one is not a failure.
        if (error as NSError).code == NSURLErrorCancelled { return }
        failure = error.localizedDescription
    }

    /// Only http(s) stays in the pane; mailto:, app links and the like go to the system.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if ["http", "https", "about", "blob", "data"].contains(scheme) { return .allow }
        NSWorkspace.shared.open(url)
        return .cancel
    }

    /// `target="_blank"` and `window.open`: open in this pane instead of a window the app has no place for.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}
