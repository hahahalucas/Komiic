import SwiftUI

struct ContentWarningPreferencesView: View {
    @EnvironmentObject private var settings: ReaderSettings
    @State private var connected = false
    @State private var loading = false
    @State private var savingTag: String?
    @State private var syncError: String?

    // These are the labels used by Komiic's first-party warning editor.
    private let tags = ["Ѫ��", "�C��", "����", "�Ա���", "���茑", "�Ԛ�", "�ֲ�", "���H", "NTR", "BL", "�ٺ�"]

    var body: some View {
        Form {
            Section {
                Text("ѡ��������Щ��ǩʱ������Ӧ�����ʾ�������ǩͬʱ����ʱ��������ȫ���أ����ģ����ʾ��")
                    .font(.subheadline).foregroundStyle(.secondary)
                if loading { ProgressView("���ڶ�ȡ����ƫ�á�") }
                if let syncError {
                    Text(syncError).font(.caption).foregroundStyle(.secondary)
                    Button("����ͬ��") { Task { await loadOfficialPreferences() } }
                }
            } footer: {
                Text(connected ? "ƫ�ûᱣ���ڱ�������ͬ���� Komiic ������" : "ƫ�ñ����ڱ�������¼ Komiic ���ͬ������ƫ�á�")
            }

            Section("���ݱ�ǩ") {
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
                            Text("��ʾ").tag(ContentWarningAction.show)
                            Text("ģ����ʾ").tag(ContentWarningAction.warn)
                            Text("��ȫ����").tag(ContentWarningAction.hide)
                        }
                        .pickerStyle(.segmented)
                        .disabled(loading || savingTag != nil)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .navigationTitle("���ݾ���ƫ��")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: settings.contentMode) { await loadOfficialPreferences() }
    }

    private func displayName(_ tag: String) -> String {
        switch tag {
        case "�C��": return "����"
        case "���茑": return "����д"
        case "�Ԛ�": return "��ɱ"
        case "���H": return "����"
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
