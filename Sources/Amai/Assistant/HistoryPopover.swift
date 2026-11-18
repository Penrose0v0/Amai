import AmaiAssistant
import SwiftUI

/// Anchored popover that lists recent chat sessions and lets the user
/// resume / delete any of them. Anchored to the history button at the
/// top-left of the chat header.
struct HistoryPopover: View {
    @Bindable var viewModel: ChatViewModel

    /// Refetched on appear and after a delete — the popover is small
    /// enough that a fresh full read is cheaper than incremental updates.
    @State private var sessions: [SessionSummary] = []
    /// Non-nil → the delete-confirm alert is up for this session.
    @State private var pendingDelete: SessionSummary?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if sessions.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(width: 320)
        .onAppear { reload() }
        .alert(
            String(localized: "删除这个对话？"),
            isPresented: deleteAlertPresented,
            presenting: pendingDelete
        ) { session in
            Button(String(localized: "取消"), role: .cancel) {
                pendingDelete = nil
            }
            Button(String(localized: "删除"), role: .destructive) {
                viewModel.deleteSession(id: session.id)
                pendingDelete = nil
                reload()
            }
        } message: { session in
            Text(String(localized: "「\(session.title)」此操作无法撤销。"))
        }
    }

    private var header: some View {
        HStack {
            Text(String(localized: "对话历史"))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(String(localized: "还没有对话"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(sessions) { session in
                    SessionRow(
                        session: session,
                        isCurrent: session.id == viewModel.currentSessionId,
                        onSelect: {
                            viewModel.loadSession(id: session.id)
                        },
                        onDelete: {
                            pendingDelete = session
                        }
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 320)
        .scrollIndicators(.visible)
    }

    private var deleteAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private func reload() {
        sessions = viewModel.recentSessions()
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let isCurrent: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(Self.relativeFormatter.localizedString(
                    for: session.updatedAt,
                    relativeTo: Date()
                ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onSelect() }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isCurrent {
            Color.accentColor.opacity(0.12)
        } else if hovering {
            Color.secondary.opacity(0.08)
        } else {
            Color.clear
        }
    }
}
