import SwiftUI

struct ImageAccountManagementView: View {
    let mode: ComicContentMode
    let ownerID: String
    @EnvironmentObject private var imageSources: ImageSourceStore
    @Environment(\.dismiss) private var dismiss
    @State private var login: ImageAccountSlot?

    var body: some View {
        NavigationStack {
            List(ImageAccountSlot.allCases) { slot in
                Button(action: { login = slot }) {
                    HStack {
                        Text("登录\(slot.title)")
                        Spacer()
                        if case .available = imageSources.status(for: slot, mode: mode, ownerID: ownerID) {
                            Image(systemName: "checkmark").accessibilityLabel("已登录")
                        }
                    }
                }
            }
            .navigationTitle("副账号").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $login) { slot in
                ImageAccountLoginView(slot: slot, mode: mode) { cookies in
                    try await imageSources.connect(slot, mode: mode, ownerID: ownerID, cookies: cookies)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ImageQuotaDetailsView: View {
    let mode: ComicContentMode
    let ownerID: String
    @ObservedObject var model: AccountProfileModel
    @EnvironmentObject private var imageSources: ImageSourceStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                row("主账号", quota: model.profile?.imageQuota, unavailable: "—")
                ForEach(ImageAccountSlot.allCases) { slot in
                    let status = imageSources.status(for: slot, mode: mode, ownerID: ownerID)
                    row(slot.title, quota: status.quota, unavailable: statusText(status))
                }
            }
            .navigationTitle("图片读取").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task {
            async let main: Void = model.load(refreshQuota: true)
            await imageSources.refresh(mode: mode)
            await main
        }
    }

    private func row(_ title: String, quota: ImageReadingQuota?, unavailable: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(quota.map { "\($0.usage)/\($0.limit)" } ?? unavailable)
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let quota { ImageQuotaResetText(date: quota.resetAt) }
        }
        .accessibilityElement(children: .combine)
    }

    private func statusText(_ status: ImageSourceStore.Status) -> String {
        switch status {
        case .disconnected: return "未登录"
        case .expired: return "登录已失效"
        case .awaitingQuota, .available: return "—"
        }
    }
}

struct ImageQuotaResetText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(resetDescription(now: context.date)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func resetDescription(now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "额度待刷新" }
        let minutes = Int(seconds / 60)
        if minutes == 0 { return "额度即将重置" }
        let hours = minutes / 60
        return hours > 0 ? "\(hours) 小时 \(minutes % 60) 分钟后重置" : "\(minutes) 分钟后重置"
    }
}
