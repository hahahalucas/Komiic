import SwiftUI

/// The entry dialog keeps the current page visible; results use the existing search route.
struct SearchPromptView: View {
    let onCancel: () -> Void
    let onSearch: (String) -> Void
    @State private var keyword = ""
    @FocusState private var focused: Bool

    private var query: String { keyword.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.42).ignoresSafeArea()
                .onTapGesture(perform: onCancel)
                .accessibilityLabel("�ر�����")
                .accessibilityAddTraits(.isButton)
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Text("����").font(.title2.bold())
                    Spacer()
                    Button(action: onCancel) { Image(systemName: "xmark").font(.body) }
                        .foregroundStyle(.secondary).accessibilityLabel("�ر�����")
                }
                VStack(spacing: 10) {
                    TextField("��������������", text: $keyword)
                        .font(.body).focused($focused)
                        .submitLabel(.search).onSubmit(submit)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Rectangle().fill(Color.secondary.opacity(0.6)).frame(height: 1)
                }
                HStack {
                    Spacer()
                    Button("����", action: submit).font(.headline)
                        .disabled(query.isEmpty).padding(.vertical, 6)
                }
            }
            .padding(28)
            .frame(maxWidth: 420)
            .background(KomiicTheme.card, in: RoundedRectangle(cornerRadius: 30))
            .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
            .padding(28)
            .accessibilityAddTraits(.isModal)
        }
    }

    private func submit() {
        guard !query.isEmpty else { return }
        focused = false
        onSearch(query)
    }
}
