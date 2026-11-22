import SwiftUI

struct OfflineView: View {
    @EnvironmentObject private var downloads: DownloadStore
    @State private var launch: ReaderLaunch?
    @State private var deleting: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeading(title: "��������", subtitle: ByteCountFormatter.string(fromByteCount: downloads.storageBytes, countStyle: .file))
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.to.line.compact").font(.title2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("�ѹ���װ���ڴ�").font(.subheadline.bold())
                        Text("�����ص��½ڣ�������Ҳ�ܼ����Ķ���")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.foregroundStyle(KomiicTheme.accent).padding(17).komiicCard()
                if downloads.items.isEmpty {
                    EmptyState(symbol: "arrow.down.circle", title: "��û�������½�", message: "���������½�Ŀ¼��������ذ�ť��")
                }
                ForEach(downloads.items) { item in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 13) {
                            RemoteImage(url: item.pages.first.flatMap { downloads.localImageURL(chapterID: item.id, pageID: $0.id) } ?? item.comic.imageUrl, aspectRatio: 0.72)
                                .frame(width: 55, height: 76).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.comic.title).font(.subheadline.bold()).lineLimit(2)
                                Text(item.chapter.displayTitle).font(.caption).foregroundStyle(.secondary)
                                Text("\(item.status.title) �� \(item.downloadedPageIDs.count)/\(item.pages.count) ҳ")
                                    .font(.caption2).foregroundStyle(KomiicTheme.accent)
                            }
                            Spacer(minLength: 0)
                            Menu {
                                if item.status == .downloading || item.status == .queued {
                                    Button("��ͣ����", systemImage: "pause") { downloads.cancel(id: item.id) }
                                } else if item.status != .completed {
                                    Button("��������", systemImage: "arrow.clockwise") { downloads.resume(id: item.id) }
                                }
                                Button("ɾ������", systemImage: "trash", role: .destructive) { deleting = item.id }
                            } label: { Image(systemName: "ellipsis").padding(8) }
                        }
                        if item.status != .completed { ProgressView(value: item.progress) }
                        if let error = item.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                        HStack {
                            Text(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button(item.status == .completed ? "�����Ķ�" : "��ʼ�Ķ�") {
                                launch = ReaderLaunch(comic: item.comic, chapter: item.chapter)
                            }.font(.caption.bold()).buttonStyle(.bordered)
                        }
                    }.padding(15).komiicCard()
                }
            }.padding(16)
        }
        .fullScreenCover(item: $launch) { item in ReaderView(comic: item.comic, chapter: item.chapter, initialPage: item.page) }
        .confirmationDialog("ɾ�������ص��½ڣ�", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("ɾ������", role: .destructive) { if let deleting { downloads.remove(id: deleting) }; deleting = nil }
        }
    }
}
