import SwiftUI

/// Barre des transferts : visible dans toutes les phases, jamais une page à part. Un toucher ouvre le détail.
struct TransfersBar: View {
    let queue: TransferQueue
    @State private var isShowingDetail = false

    var body: some View {
        Button {
            isShowingDetail = true
        } label: {
            VStack(alignment: .leading, spacing: Spacing.hair) {
                HStack(spacing: Spacing.tight) {
                    Image(systemName: queue.hasActive ? "arrow.up.arrow.down.circle" : "checkmark.circle")
                        .foregroundStyle(Palette.accentInk)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(queue.summary(now: context.date))
                            .font(TypeScale.label)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Spacing.tight)
                    Image(systemName: "chevron.up")
                        .font(TypeScale.caption)
                        .foregroundStyle(Palette.inkFaint)
                }
                if let fraction = overallFraction {
                    ThinProgress(fraction: fraction)
                }
            }
            .padding(.horizontal, Spacing.page).padding(.vertical, Spacing.tight)
            .frame(minHeight: Spacing.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        .accessibilityLabel("Transferts")
        .accessibilityHint("Affiche le détail des transferts.")
        .sheet(isPresented: $isShowingDetail) {
            TransfersSheet(queue: queue)
        }
    }

    /// Avancement de l'ensemble des transferts en cours, quand leurs tailles sont connues.
    private var overallFraction: Double? {
        let running = queue.items.filter(\.isActive)
        guard !running.isEmpty else { return nil }
        let totals = running.compactMap(\.totalBytes)
        guard totals.count == running.count else { return nil }
        let total = totals.reduce(0, +)
        guard total > 0 else { return nil }
        return min(1, Double(running.map(\.transferredBytes).reduce(0, +)) / Double(total))
    }
}

/// Le détail des transferts : en cours d'abord, puis les terminés, du plus récent au plus ancien.
struct TransfersSheet: View {
    let queue: TransferQueue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if queue.hasActive {
                    // Toute attente a une phrase, et celle-ci est la limite qu'iOS impose.
                    Section {
                        Text("Garde Fil ouvert jusqu'à la fin : iOS suspend les transferts peu après que Fil passe en arrière-plan. L'écran reste allumé en attendant.")
                            .font(TypeScale.label)
                            .foregroundStyle(Palette.inkSoft)
                            .listRowBackground(Palette.accentWash)
                    }
                }
                Section {
                    ForEach(ordered) { item in
                        TransferRow(item: item, queue: queue)
                            .listRowBackground(Palette.surface)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .navigationTitle("Transferts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if queue.hasFinished {
                        Button("Effacer les terminés") { queue.clearFinished() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

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
                    .font(.title3)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(TypeScale.body)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.phrase(now: context.date))
                        .font(TypeScale.label)
                        .foregroundStyle(isFailure ? Palette.alert : Palette.inkSoft)
                        .lineLimit(3)
                    Text(item.connectionName)
                        .font(TypeScale.caption)
                        .foregroundStyle(Palette.inkFaint)
                        .lineLimit(1)
                    if item.isActive {
                        ThinProgress(fraction: item.state == .running ? item.fraction : nil)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: Spacing.tight)
                action
            }
            .padding(.vertical, Spacing.hair)
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
    private var action: some View {
        if item.isActive {
            iconButton("xmark.circle", label: "Annuler") { queue.cancel(item.id) }
        } else if queue.canRetry(item.id) {
            iconButton("arrow.clockwise", label: "Réessayer") { queue.retry(item.id) }
        } else if item.state == .done, item.direction == .download, !item.isFolder {
            // Ouvrir dans une autre app, enregistrer dans Photos, envoyer : la feuille de partage d'iOS.
            ShareLink(item: item.localURL) {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: Spacing.control, height: Spacing.control)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Partager")
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: Spacing.control, height: Spacing.control)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}
