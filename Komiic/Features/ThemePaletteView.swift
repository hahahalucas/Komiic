import SwiftUI

struct ThemePaletteView: View {
    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let theme = KomiicTheme(palette: settings.palette)
        NavigationStack {
            List {
                Section("主题色") {
                    ForEach(AppPalette.allCases) { palette in
                        paletteRow(palette)
                            .listRowBackground(theme.card)
                    }
                }
                Section("外观") {
                    Picker("外观", selection: $settings.theme) {
                        ForEach(AppTheme.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(theme.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .navigationTitle("调色盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .tint(theme.accent)
        .preferredColorScheme(settings.theme.colorScheme)
    }

    private func paletteRow(_ palette: AppPalette) -> some View {
        let selected = settings.palette == palette
        return Button { settings.palette = palette } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(KomiicTheme(palette: palette).accent)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text(palette.title)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
