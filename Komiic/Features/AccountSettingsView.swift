import SwiftUI
import UserNotifications
import UniformTypeIdentifiers

private struct WebDestination: Identifiable {
    let path: String
    let title: String
    var id: String { path }
    var url: URL { URL(string: "https://komiic.cc\(path)")! }
}

struct AccountView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadStore
    @Environment(\.dismiss) private var dismiss
    @State private var website: WebDestination?
    @State private var connected = false
    @State private var signingOut = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 17) {
                        Image(systemName: connected ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                            .font(.system(size: 55)).foregroundStyle(KomiicTheme.accent)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(connected ? "已连接 Komiic" : "欢迎来到 Komiic").font(.title3.bold())
                            Text(connected ? "使用官网会话访问漫画" : "登录账号，连接更多故事")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(connected ? "查看官网账号" : "登录 Komiic") {
                                website = WebDestination(path: connected ? "/profile" : "/login", title: "Komiic 账号")
                            }.font(.subheadline.bold())
                        }
                        Spacer(minLength: 0)
                    }.padding(20).komiicCard()
                    SectionHeading(title: "我的阅读", subtitle: "本机统计")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        stat("阅读漫画", value: String(library.readComicCount), symbol: "book")
                        stat("阅读章节", value: String(library.readChapterCount), symbol: "doc.text")
                        stat("喜爱漫画", value: String(library.favorites.count), symbol: "heart")
                        stat("离线章节", value: String(downloads.items.filter { $0.status == .completed }.count), symbol: "arrow.down.circle")
                    }
                    VStack(spacing: 0) {
                        NavigationLink { SettingsView() } label: { menuRow("阅读与应用设置", symbol: "gearshape") }
                        Divider().padding(.leading, 50)
                        NavigationLink { BlockedComicsView() } label: { menuRow("屏蔽漫画", symbol: "eye.slash") }
                        Divider().padding(.leading, 50)
                        Button { website = WebDestination(path: "/settings/warnings", title: "内容警告偏好") } label: {
                            menuRow("官网内容警告偏好", symbol: "shield")
                        }
                    }.komiicCard().buttonStyle(.plain)
                    SectionHeading(title: "Komiic 云端资料")
                    Text("本机喜爱、书签与书柜独立保存。云端收藏及账号资料可在官网管理。")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                    HStack(spacing: 12) {
                        cloudButton("云端喜爱", symbol: "heart", path: "/favorite")
                        cloudButton("云端书柜", symbol: "books.vertical", path: "/folder")
                        cloudButton("云端书签", symbol: "bookmark", path: "/bookmarks")
                    }
                    if connected {
                        Button("退出官网会话", role: .destructive) { signingOut = true }
                            .buttonStyle(.bordered).frame(maxWidth: .infinity)
                    }
                }.padding(18)
            }
            .background(KomiicTheme.canvas)
            .navigationTitle("账号与设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .sheet(item: $website) { destination in
                WebsiteView(url: destination.url, title: destination.title, onClose: updateConnection)
            }
            .task { await WebCookieBridge.synchronize(); updateConnection() }
            .confirmationDialog("退出此 App 中的 Komiic 官网会话？本机阅读资料会保留。", isPresented: $signingOut, titleVisibility: .visible) {
                Button("退出会话", role: .destructive) { Task { await WebCookieBridge.clear(); updateConnection() } }
            }
        }
    }
    private func updateConnection() {
        connected = (HTTPCookieStorage.shared.cookies(for: URL(string: "https://komiic.cc")!) ?? []).contains {
            $0.name == "komiic-access-token" && ($0.expiresDate == nil || $0.expiresDate! > Date())
        }
    }
    private func stat(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(KomiicTheme.accent)
            Text(value).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).komiicCard()
    }
    private func menuRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).foregroundStyle(KomiicTheme.accent).frame(width: 24)
            Text(title).font(.subheadline).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }.padding(17).contentShape(Rectangle())
    }
    private func cloudButton(_ title: String, symbol: String, path: String) -> some View {
        Button { website = WebDestination(path: path, title: title) } label: {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption)
            }.frame(maxWidth: .infinity).padding(.vertical, 19).komiicCard()
        }.buttonStyle(.plain).foregroundStyle(KomiicTheme.accent)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: ReaderSettings
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var library: LibraryStore
    @State private var clearing: String?
    @State private var showExport = false
    @State private var showGuide = false
    @State private var notificationError: String?
    var body: some View {
        Form {
            Section("阅读") {
                Picker("图片载入方式", selection: $settings.loadingMode) {
                    ForEach(ImageLoadingMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("阅读方式", selection: $settings.readingMode) {
                    ForEach(ReadingMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("缓存自动清除", selection: $settings.cachePolicy) {
                    ForEach(CachePolicy.allCases) { Text($0.title).tag($0) }
                }
                Picker("电子墨水模式", selection: $settings.einkMode) {
                    ForEach(EInkMode.allCases) { Text($0.title).tag($0) }
                }
                if UIDevice.current.userInterfaceIdiom == .pad {
                    LabeledContent("画面方向", value: "跟随 iPad 窗口")
                } else {
                    Picker("画面方向", selection: $settings.orientation) {
                        ForEach(ReaderOrientation.allCases) { Text($0.title).tag($0) }
                    }
                }
                Toggle("柔和显示图片", isOn: $settings.dimImages)
                Button("查看阅读说明") { showGuide = true }
            }
            Section {
                Toggle("下载完成提醒", isOn: Binding(get: { settings.notificationsEnabled }, set: setNotifications))
                if let notificationError { Text(notificationError).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("通知") } footer: { Text("下载在 App 打开时进行。章节更新等云端通知由 Komiic 官网提供。") }
            Section("常规") {
                Picker("外观", selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("语言", value: "简体中文")
            }
            Section {
                LabeledContent("离线漫画", value: bytes(downloads.storageBytes))
                LabeledContent("阅读缓存", value: bytes(downloads.cacheBytes))
                LabeledContent("可用储存空间", value: bytes(downloads.availableBytes))
                VStack(alignment: .leading, spacing: 6) {
                    Text("离线储存位置")
                    Text("文件 → 我的 iPhone / iPad → Komiic → KomiicOffline")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
                Button("导出离线文件夹到文件 App") { showExport = true }
                Button("扫描并还原离线章节") { downloads.restore() }
                Button("清除阅读缓存") { clearing = "cache" }
                Button("删除全部离线漫画", role: .destructive) { clearing = "downloads" }
                Button("清除阅读历史", role: .destructive) { clearing = "history" }
                Button("删除本机资料库", role: .destructive) { clearing = "library" }
            } header: { Text("储存与数据") } footer: {
                Text("缓存与永久下载分别保存。可通过文件 App 备份或拷入 KomiicOffline 文件夹，然后扫描还原。")
            }
            Section("网络") {
                NavigationLink { NetworkDiagnosticsView() } label: { Label("连接检测与重新连线", systemImage: "network") }
            }
            Section("关于") {
                LabeledContent("Komiic for iOS", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.0")
                Link("访问 Komiic 官网", destination: URL(string: "https://komiic.cc")!)
                Text("独立 SwiftUI 客户端，与 Komiic 官方无隶属关系。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(clearTitle, isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }), titleVisibility: .visible) {
            Button("确认删除", role: .destructive) {
                switch clearing {
                case "cache": downloads.clearCache()
                case "downloads": downloads.removeAll()
                case "history": library.clearHistory()
                case "library": library.clearLocalData()
                default: break
                }
                clearing = nil
            }
        }
        .sheet(isPresented: $showExport) { FolderExportView(url: downloads.directoryURL) }
        .sheet(isPresented: $showGuide) { ReadingGuideView() }
    }
    private var clearTitle: String {
        switch clearing {
        case "cache": return "清除阅读缓存？已下载的章节会保留。"
        case "downloads": return "删除全部离线漫画？此操作会移除永久下载文件。"
        case "history": return "清除本机阅读历史和阅读统计？"
        default: return "删除本机喜爱、书签、书柜、屏蔽与阅读历史？离线下载会保留。"
        }
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    private func setNotifications(_ enabled: Bool) {
        guard enabled else { settings.notificationsEnabled = false; return }
        Task {
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                settings.notificationsEnabled = allowed
                notificationError = allowed ? nil : "通知尚未获准，可前往 iOS 设置开启。"
            } catch { notificationError = error.localizedDescription }
        }
    }
}

struct BlockedComicsView: View {
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        List {
            if library.blockedComicIDs.isEmpty { Text("没有屏蔽的漫画").foregroundStyle(.secondary) }
            ForEach(library.blockedComicIDs.sorted(), id: \.self) { id in
                HStack {
                    Text("漫画 #\(id)").font(.subheadline)
                    Spacer()
                    Button("解除屏蔽") { library.unblock(comicID: id) }.font(.caption)
                }
            }
        }.navigationTitle("屏蔽漫画").navigationBarTitleDisplayMode(.inline)
    }
}

struct NetworkDiagnosticsView: View {
    @State private var checking = false
    @State private var result: String?
    @State private var success = false
    var body: some View {
        List {
            Section("连接信息") {
                LabeledContent("服务器", value: "komiic.cc")
                LabeledContent("传输方式", value: "HTTPS")
                Text("检测会请求一次最新漫画列表。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if checking { ProgressView("正在检测连接…") }
                if let result { Label(result, systemImage: success ? "checkmark.circle" : "exclamationmark.triangle").font(.subheadline) }
                Button("检测并重新连接") { Task { await check() } }.disabled(checking)
            }
        }.navigationTitle("网络诊断").navigationBarTitleDisplayMode(.inline)
            .task { await check() }
    }
    @MainActor private func check() async {
        checking = true; result = nil
        await WebCookieBridge.synchronize()
        URLCache.shared.removeAllCachedResponses()
        let start = Date()
        do {
            let comics = try await KomiicAPI().catalog(feed: .updated)
            try Task.checkCancellation()
            result = "连接正常 · 收到 \(comics.count) 部漫画 · \(Int(Date().timeIntervalSince(start) * 1_000)) ms"
            success = true
        } catch is CancellationError {
        } catch { result = error.localizedDescription; success = false }
        checking = false
    }
}

private struct ReadingGuideView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Label("轻点漫画页面可显示或收起工具栏。", systemImage: "hand.tap")
                Label("通过底部滑杆或翻页按钮跳转页面。", systemImage: "slider.horizontal.3")
                Label("轻点书签保存位置，下次可从书签继续。", systemImage: "bookmark")
                Label("在章节列表下载漫画，完成后支持离线阅读。", systemImage: "arrow.down.circle")
                Label("墨水模式使用灰阶画面，并减少工具栏动画。", systemImage: "circle.lefthalf.filled")
                Label("图片访问受官网账号权限与每日额度限制。", systemImage: "person.crop.circle")
            }.font(.subheadline)
            .navigationTitle("阅读说明").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}

private struct FolderExportView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}
