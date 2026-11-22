import SwiftUI
import WebKit

struct WebsiteView: View {
    let url: URL
    var title = "Komiic ����"
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
                    EmptyState(symbol: "wifi.exclamationmark", title: "��ҳδ������", message: errorMessage,
                               actionTitle: "����", action: { self.errorMessage = nil; reloadID = UUID() })
                    .background(KomiicTheme.canvas)
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Link(destination: url) { Image(systemName: "safari") }.accessibilityLabel("��������д�")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("���") {
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

@MainActor
enum WebCookieBridge {
    private static var clearingSessions = 0
    private static var synchronizationGeneration = UUID()

    @MainActor static func synchronize(preferWeb: Bool = false) async {
        guard clearingSessions == 0 else { return }
        let generation = synchronizationGeneration
        let webStore = WKWebsiteDataStore.default().httpCookieStore
        let webCookies = await webStore.allCookies().filter(isOfficial)
        guard clearingSessions == 0, synchronizationGeneration == generation else { return }
        let nativeCookies = (HTTPCookieStorage.shared.cookies ?? []).filter(isOfficial)
        // Compare sessions by cookie scope: the general and H sites may have
        // different host-only tokens. Refresh must keep each access/refresh pair together.
        let scopes = Set((webCookies + nativeCookies).map { "\($0.domain)|\($0.path)" })
        for scope in scopes {
            guard clearingSessions == 0, synchronizationGeneration == generation else { return }
            let web = webCookies.filter { "\($0.domain)|\($0.path)" == scope }
            let native = nativeCookies.filter { "\($0.domain)|\($0.path)" == scope }
            let webToken = web.first { $0.name == "komiic-access-token" }
            let nativeToken = native.first { $0.name == "komiic-access-token" }
            if !preferWeb, let nativeToken,
               webToken == nil || tokenExpiry(nativeToken) > tokenExpiry(webToken!) {
                for cookie in native {
                    guard clearingSessions == 0, synchronizationGeneration == generation else { return }
                    await webStore.setCookie(cookie)
                }
            } else {
                if preferWeb {
                    for cookie in native { HTTPCookieStorage.shared.deleteCookie(cookie) }
                }
                for cookie in web { HTTPCookieStorage.shared.setCookie(cookie) }
            }
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
        clearingSessions += 1
        synchronizationGeneration = UUID()
        defer { clearingSessions -= 1 }
        await KomiicAPI.beginClearingSession()
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        for cookie in await cookieStore.allCookies()
            where cookie.domain == "komiic.cc" || cookie.domain.hasSuffix(".komiic.cc") {
            await cookieStore.deleteCookie(cookie)
        }
        for cookie in HTTPCookieStorage.shared.cookies ?? []
            where cookie.domain == "komiic.cc" || cookie.domain.hasSuffix(".komiic.cc") {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
        await KomiicAPI.endClearingSession()
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
