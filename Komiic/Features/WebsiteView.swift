import SwiftUI
import WebKit

struct WebsiteView: View {
    let url: URL
    var title = "Komiic 官网"
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.komiicTheme) private var theme
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
                    .background(theme.canvas)
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

struct ImageAccountLoginView: View {
    let slot: ImageAccountSlot
    let mode: ComicContentMode
    let connect: ([HTTPCookie]) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var websiteDataStore = WKWebsiteDataStore.nonPersistent()
    @State private var loading = true
    @State private var webError: String?
    @State private var connectionError: String?
    @State private var reloadID = UUID()
    @State private var saving = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                OfficialWebView(url: mode.baseURL.appendingPathComponent("login"), loading: $loading,
                                errorMessage: $webError, websiteDataStore: websiteDataStore)
                    .id(reloadID)
                if loading || saving { ProgressView().padding(10).background(.regularMaterial, in: Capsule()) }
                if let webError {
                    EmptyState(symbol: "wifi.exclamationmark", title: "网页未能载入", message: webError,
                               actionTitle: "重试", action: { self.webError = nil; reloadID = UUID() })
                }
            }
            .navigationTitle("登录\(slot.title)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        saving = true
                        Task {
                            defer { saving = false }
                            do {
                                let cookies = await websiteDataStore.httpCookieStore.allCookies()
                                try await connect(cookies)
                                dismiss()
                            } catch { connectionError = error.localizedDescription }
                        }
                    }
                    .disabled(saving || loading || webError != nil)
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .alert("未能连接账号", isPresented: Binding(get: { connectionError != nil }, set: { if !$0 { connectionError = nil } })) {
            Button("好", role: .cancel) { connectionError = nil }
        } message: { Text(connectionError ?? "") }
    }
}

@MainActor
enum WebCookieBridge {
    private static var clearingSessions = 0
    private static var synchronizationGeneration = UUID()
    private static var synchronizationTask: Task<Void, Never>?

    @MainActor static func synchronize(preferWeb: Bool = false) async {
        if let running = synchronizationTask {
            await running.value
            if !preferWeb { return }
        }
        let id = UUID()
        synchronizationGeneration = id
        let task = Task { await performSynchronization(preferWeb: preferWeb) }
        synchronizationTask = task
        await task.value
        if synchronizationGeneration == id { synchronizationTask = nil }
    }

    private static func performSynchronization(preferWeb: Bool) async {
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
        guard clearingSessions == 0, synchronizationGeneration == generation else { return }
        let currentCookies = HTTPCookieStorage.shared.cookies ?? []
        let changedAccounts = Set(ComicContentMode.allCases.filter {
            SessionCookieStore.credentialSignature(nativeCookies, mode: $0) != SessionCookieStore.credentialSignature(currentCookies, mode: $0)
        })
        SessionCookieStore.shared.capture(changedAccounts: changedAccounts)
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
        synchronizationTask?.cancel()
        synchronizationTask = nil
        SessionCookieStore.shared.beginClearing()
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
        SessionCookieStore.shared.endClearing()
    }
}

private struct OfficialWebView: UIViewRepresentable {
    let url: URL
    @Binding var loading: Bool
    @Binding var errorMessage: String?
    var websiteDataStore: WKWebsiteDataStore? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore ?? .default()
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
            if parent.websiteDataStore == nil { Task { await WebCookieBridge.synchronize() } }
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
            } else if parent.websiteDataStore == nil && (url.scheme == "https" || url.scheme == "http") {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}
