import SwiftUI

/// 侧栏搜索框。焦点状态由 AppCoordinator 统一管理（Tab / Cmd+F 进入，Esc 退出）。
struct SearchBar: View {
    @Binding var text: String
    @Binding var isFocused: Bool

    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Palette.secondaryText)

            TextField("搜索台名 / 拼音 / 台号", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(Palette.primaryText)
                .focused($fieldFocused)
                .onSubmit {
                    isFocused = false
                    fieldFocused = false
                }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Palette.secondaryText)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(fieldFocused ? Palette.accent.opacity(0.8) : Palette.stroke, lineWidth: 1)
        )
        .onChange(of: isFocused) { newValue in
            if fieldFocused != newValue { fieldFocused = newValue }
        }
        .onChange(of: fieldFocused) { newValue in
            if isFocused != newValue { isFocused = newValue }
        }
    }
}
