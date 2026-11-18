import SwiftUI

/// 聊天输入行（移植自 Eira）：左侧"带上屏幕"开关、胶囊形输入框、发送 / 停止按钮。
/// Eira 的"+"是附加图片；Amai 里换成"随这条消息带上当前屏幕"，截图由感知层按隐私策略获取。
///
/// The field and buttons share one look: a translucent fill plus a top-lit rim
/// highlight. Tune `fillOpacity` / `rimHighlight` to taste.
struct InputCardView: View {
    @Bindable var viewModel: ChatViewModel

    /// Fill opacity of the field / button surfaces (0 = fully transparent).
    private let fillOpacity: Double = 0.12
    /// Strength of the top-edge rim highlight (0 = none).
    private let rimHighlight: Double = 0.0
    private let controlSize: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                attachButton
                inputField
                sendButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    // MARK: - Field

    private var inputField: some View {
        ChatInputTextView(
            text: $viewModel.input,
            placeholder: String(localized: "问点什么…"),
            maxVisibleLines: 6,
            onSubmit: { viewModel.send() }
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .surface(Capsule(style: .continuous), fill: Color.white.opacity(fillOpacity), rim: rimHighlight)
    }

    // MARK: - Buttons

    private var attachButton: some View {
        Button { viewModel.attachScreen.toggle() } label: {
            Image(systemName: viewModel.attachScreen ? "rectangle.inset.filled.and.person.filled" : "macwindow")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(viewModel.attachScreen ? Color.white : Color.primary)
                .frame(width: controlSize, height: controlSize)
                .surface(
                    Circle(),
                    fill: viewModel.attachScreen ? AnyShapeStyle(Color.accentColor)
                                                 : AnyShapeStyle(Color.white.opacity(fillOpacity)),
                    rim: rimHighlight
                )
        }
        .buttonStyle(.plain)
        .help(viewModel.attachScreen ? String(localized: "这条消息会带上当前窗口的截图。点击取消。") : String(localized: "随这条消息带上当前窗口的截图"))
    }

    @ViewBuilder
    private var sendButton: some View {
        if viewModel.isStreaming {
            Button { viewModel.cancelStreaming() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: controlSize, height: controlSize)
                    .surface(Circle(), fill: Color.white.opacity(fillOpacity), rim: rimHighlight)
            }
            .buttonStyle(.plain)
            .help(String(localized: "停止"))
        } else {
            let active = !viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button { viewModel.send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    // White glyph on the blue fill when active; dimmed when empty.
                    .foregroundStyle(active ? Color.white : Color.secondary)
                    .frame(width: controlSize, height: controlSize)
                    .surface(
                        Circle(),
                        fill: active ? AnyShapeStyle(Color.accentColor)
                                     : AnyShapeStyle(Color.white.opacity(fillOpacity)),
                        rim: rimHighlight
                    )
                    .animation(.easeInOut(duration: 0.15), value: active)
            }
            .buttonStyle(.plain)
            .disabled(!active)
            .keyboardShortcut(.return, modifiers: .command)
            .help(String(localized: "发送 (⌘↩)"))
        }
    }
}

private extension View {
    /// Fill + top-lit rim highlight, clipped to `shape`. Shared by the input
    /// field and its round buttons.
    func surface<S: InsettableShape, F: ShapeStyle>(_ shape: S, fill: F, rim: Double) -> some View {
        self
            .background(fill, in: shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(rim), .white.opacity(rim * 0.12)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
    }
}
