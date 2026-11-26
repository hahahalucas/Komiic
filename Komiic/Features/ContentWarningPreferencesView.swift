import SwiftUI

struct ContentWarningPreferencesView: View {
    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.komiicTheme) private var theme
    @State private var connected = false
    @State private var loading = false
    @State private var savingTag: String?
    @State private var syncError: String?

    // These are the labels used by Komiic's first-party warning editor.
    private let tags = ["血腥", "獵奇", "暴力", "性暴力", "性描寫", "自殺", "恐怖", "近親", "NTR", "BL", "百合"]

    var body: some View {
        Form {
            Section {
                Text("选择遇到这些标签时，漫画应如何显示。多个标签同时出现时，优先完全隐藏，其次模糊显示。")
                    .font(.subheadline).foregroundStyle(.secondary)
                if loading { ProgressView("正在读取官网偏好…") }
                if let syncError {
                    Text(syncError).font(.caption).foregroundStyle(.secondary)
                    Button("重试同步") { Task { await loadOfficialPreferences() } }
                }
            } footer: {
                Text(connected ? "偏好会保存在本机，并同步到 Komiic 官网。" : "偏好保存在本机。登录 Komiic 后可同步官网偏好。")
            }
            .listRowBackground(theme.card)

            Section("内容标签") {
                ForEach(tags, id: \.self) { tag in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(displayName(tag)).font(.subheadline.weight(.medium))
                            Spacer()
                            if savingTag == tag { ProgressView().controlSize(.small) }
                        }
                        Picker(displayName(tag), selection: Binding(
                            get: { settings.warningAction(for: tag) },
                            set: { action in update(tag: tag, action: action) }
                        )) {
                            Text("显示").tag(ContentWarningAction.show)
                            Text("模糊显示").tag(ContentWarningAction.warn)
                            Text("完全隐藏").tag(ContentWarningAction.hide)
                        }
                        .pickerStyle(.segmented)
                        .disabled(loading || savingTag != nil)
                    }
                    .padding(.vertical, 5)
                    .listRowBackground(theme.card)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
        .navigationTitle("内容警告偏好")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: settings.contentMode) { await loadOfficialPreferences() }
    }

    private func displayName(_ tag: String) -> String {
        switch tag {
        case "獵奇": return "猎奇"
        case "性描寫": return "性描写"
        case "自殺": return "自杀"
        case "近親": return "近亲"
        default: return tag
        }
    }

    @MainActor private func loadOfficialPreferences() async {
        loading = true
        syncError = nil
        defer { loading = false }
        let mode = settings.contentMode
        let result = await settings.syncWarningPreferences(mode: mode)
        guard !Task.isCancelled, settings.contentMode == mode else { return }
        connected = OfficialAccountSession.isConnected(mode: mode)
        syncError = result
    }

    @MainActor private func update(tag: String, action: ContentWarningAction) {
        settings.setWarningPreference(tag: tag, action: action)
        syncError = nil
        guard connected else { return }
        savingTag = tag
        Task {
            defer { savingTag = nil }
            syncError = await settings.syncWarningPreferences(mode: settings.contentMode)
        }
    }
}
