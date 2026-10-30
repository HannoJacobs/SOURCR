import SwiftUI
import WebKit

/// A persistent website session, independent of SOURCR's API credentials.
@MainActor @Observable
final class GitHubBrowserModel: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView = WKWebView()
    var errorMessage: String?
    var loading = false

    override init() {
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func load(_ url: URL) {
        errorMessage = nil
        loading = true
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        errorMessage = nil
        loading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        AppDiagnostics.info(.appState, "attached browser navigation finished host=\(webView.url?.host ?? "unknown")")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    private func failed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        loading = false
        errorMessage = error.localizedDescription
        AppDiagnostics.error(.appState, "attached browser navigation failed code=\((error as NSError).code)")
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

struct GitHubBrowserPane: View {
    @Environment(AppState.self) private var appState
    let url: URL
    let title: String
    let requestID: UUID
    @State private var browser = GitHubBrowserModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HeaderIconButton(systemName: "chevron.left", help: "Back") { browser.webView.goBack() }
                HeaderIconButton(systemName: "chevron.right", help: "Forward") { browser.webView.goForward() }
                HeaderIconButton(systemName: "arrow.clockwise", help: "Reload", spinning: browser.loading) {
                    browser.webView.reload()
                }
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                HeaderIconButton(systemName: "xmark", help: "Close browser") { appState.clearSelection() }
            }
            .padding(6)
            Divider()
            if let error = browser.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
            GitHubWebView(browser: browser)
        }
        .onAppear { browser.load(url) }
        .onChange(of: requestID) { _, _ in browser.load(url) }
    }
}

private struct GitHubWebView: NSViewRepresentable {
    let browser: GitHubBrowserModel
    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
