import SwiftUI
import WebKit

struct WebsiteView: View {
    let url: URL
    var title = "Komiic 官网"
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var reloadID = UUID()
    @State private var ready = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                if ready {
                    OfficialWebView(url: url, loading: $loading, errorMessage: $errorMessage)
                        .id(reloadID)
                }
                if loading { ProgressView().padding(10).background(.regularMaterial, in: Capsule()) }
                if let errorMessage {
                    EmptyState(symbol: "wifi.exclamationmark", title: "网页未能载入", message: errorMessage,
                               actionTitle: "重试", action: { self.errorMessage = nil; reloadID = UUID() })
                    .background(KomiicTheme.canvas)
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Link(destination: url) { Image(systemName: "safari") }.accessibilityLabel("在浏览器中打开")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        Task {
                            await WebCookieBridge.synchronize(preferWeb: true)
                            onClose?()
                            dismiss()
                        }
                    }
                }
            }
        }
        .task { await WebCookieBridge.synchronize(); ready = true }
        .onDisappear {
            Task {
                await WebCookieBridge.synchronize(preferWeb: true)
                onClose?()
            }
        }
    }
}

enum WebCookieBridge {
    @MainActor static func synchronize(preferWeb: Bool = false) async {
        let webStore = WKWebsiteDataStore.default().httpCookieStore
        let webCookies = await webStore.allCookies().filter(isOfficial)
        let nativeCookies = (HTTPCookieStorage.shared.cookies ?? []).filter(isOfficial)
        let webToken = webCookies.first { $0.name == "komiic-access-token" }
        let nativeToken = nativeCookies.first { $0.name == "komiic-access-token" }
        // Refresh rotates the whole cookie session. Keep the access/refresh pair together.
        if !preferWeb, let nativeToken,
           webToken == nil || tokenExpiry(nativeToken) > tokenExpiry(webToken!) {
            for cookie in nativeCookies { await webStore.setCookie(cookie) }
        } else {
            if preferWeb {
                for cookie in nativeCookies { HTTPCookieStorage.shared.deleteCookie(cookie) }
            }
            for cookie in webCookies { HTTPCookieStorage.shared.setCookie(cookie) }
        }
    }

    private static func isOfficial(_ cookie: HTTPCookie) -> Bool {
        cookie.domain == "komiic.cc" || cookie.domain.hasSuffix(".komiic.cc")
    }

    private static func tokenExpiry(_ cookie: HTTPCookie) -> TimeInterval {
        let segments = cookie.value.split(separator: ".")
        if segments.count == 3 {
            var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            if let data = Data(base64Encoded: payload),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let expiry = object["exp"] as? Double { return expiry }
        }
        return cookie.expiresDate?.timeIntervalSince1970 ?? 0
    }

    @MainActor static func clear() async {
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        for cookie in await cookieStore.allCookies()
            where cookie.domain == "komiic.cc" || cookie.domain.hasSuffix(".komiic.cc") {
            await cookieStore.deleteCookie(cookie)
        }
        for cookie in HTTPCookieStorage.shared.cookies ?? []
            where cookie.domain == "komiic.cc" || cookie.domain.hasSuffix(".komiic.cc") {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }
}

private struct OfficialWebView: UIViewRepresentable {
    let url: URL
    @Binding var loading: Bool
    @Binding var errorMessage: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: OfficialWebView
        init(_ parent: OfficialWebView) { self.parent = parent }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.loading = true
            parent.errorMessage = nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            Task { await WebCookieBridge.synchronize() }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
            parent.errorMessage = error.localizedDescription
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
            parent.errorMessage = error.localizedDescription
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            // Keep credentials in the official HTTPS site; external links open in Safari.
            if url.scheme == "https", let host = url.host,
               host == "komiic.cc" || host.hasSuffix(".komiic.cc") || host == "komiic.com" || host.hasSuffix(".komiic.com") {
                decisionHandler(.allow)
            } else if url.scheme == "https" || url.scheme == "http" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}
