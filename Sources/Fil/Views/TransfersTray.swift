import AppKit
import SwiftUI

/// Plateau des transferts : visible dans toutes les phases, jamais une page à part.
struct TransfersTray: View {
    let queue: TransferQueue
    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: Spacing.regular) {
                Button {
                    isExpanded.toggle()
                } label: {
                    Label("Transferts", systemImage: isExpanded ? "chevron.down" : "chevron.up")
                        .font(TypeScale.bodyStrong)
                        .foregroundStyle(Palette.ink)
                }
                .buttonStyle(.plain)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(queue.summary(now: context.date))
                        .font(TypeScale.label)
                        .foregroundStyle(Palette.inkSoft)
                }
                Spacer()
                if queue.hasFinished {
                    Button("Effacer les terminés") { queue.clearFinished() }
                        .buttonStyle(QuietButtonStyle())
                }
            }
            .padding(.horizontal, Spacing.page).padding(.vertical, 10)
            if isExpanded {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(ordered) { item in
                            TransferRow(item: item, queue: queue)
                        }
                    }
                }
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(Palette.surface)
    }

    /// En cours d'abord, dans l'ordre de départ ; puis les terminés, du plus récent au plus ancien.
    private var ordered: [TransferItem] {
        queue.items.filter(\.isActive)
            + queue.items.filter { !$0.isActive }.sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
    }
}

struct TransferRow: View {
    let item: TransferItem
    let queue: TransferQueue

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(alignment: .center, spacing: Spacing.regular) {
                Image(systemName: item.direction == .download ? "arrow.down.circle" : "arrow.up.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Spacing.tight) {
                        Text(item.name)
                            .font(TypeScale.body)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(item.connectionName)
                            .font(TypeScale.caption)
                            .foregroundStyle(Palette.inkFaint)
                            .lineLimit(1)
                    }
                    Text(item.phrase(now: context.date))
                        .font(TypeScale.label)
                        .foregroundStyle(isFailure ? Palette.alert : Palette.inkSoft)
                        .lineLimit(2)
                    if item.isActive {
                        ThinProgress(fraction: item.state == .running ? item.fraction : nil)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: Spacing.tight)
                actions
            }
            .padding(.horizontal, Spacing.page).padding(.vertical, 8)
        }
    }

    private var isFailure: Bool {
        if case .failed = item.state { return true }
        return false
    }

    private var tint: Color {
        if isFailure { return Palette.alert }
        return item.state == .done ? Palette.accentInk : Palette.inkSoft
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: Spacing.tight) {
            if item.isActive {
                iconButton("xmark.circle", help: "Annuler") { queue.cancel(item.id) }
            } else if queue.canRetry(item.id) {
                iconButton("arrow.clockwise", help: "Réessayer") { queue.retry(item.id) }
            } else if item.state == .done, item.direction == .download {
                iconButton("magnifyingglass", help: "Afficher dans le Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.localURL])
                }
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14))
        }
        .buttonStyle(ToolButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}
