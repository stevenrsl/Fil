import AppKit
import SwiftUI

/// Plateau des transferts : visible dans toutes les phases, jamais une page à part.
struct TransfersTray: View {
    let queue: TransferQueue
    let edits: EditCoordinator
    @State private var isExpanded = true
    @State private var pendingDiscard: EditSession?

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
                // Le débit et le temps restant bougent seulement pendant un transfert : au repos, rien ne se redessine.
                TimelineView(.periodic(from: .now, by: queue.hasActive ? 1 : 3600)) { context in
                    Text(summary(now: context.date))
                        .font(TypeScale.label)
                        .foregroundStyle(Palette.inkSoft)
                        .help(queue.hasActive ? "Le Mac ne se met pas en veille tant qu'un transfert tourne. Une notification sonne à la fin si Fil n'est pas devant." : "")
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
                        ForEach(edits.sessions) { session in
                            EditRow(session: session, edits: edits) { pendingDiscard = session }
                        }
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
        .confirmationDialog(
            "Abandonner les modifications de « \(pendingDiscard?.name ?? "") » ?",
            isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
            presenting: pendingDiscard
        ) { session in
            Button("Abandonner", role: .destructive) { edits.discard(session.id) }
        } message: { _ in
            Text("Ce qui n'a pas été envoyé au serveur sera perdu.")
        }
    }

    private func summary(now: Date) -> String {
        var parts: [String] = []
        if !queue.items.isEmpty { parts.append(queue.summary(now: now)) }
        if !edits.sessions.isEmpty { parts.append(Format.plural(edits.sessions.count, "fichier en modification", "fichiers en modification")) }
        return parts.joined(separator: " · ")
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
        TimelineView(.periodic(from: .now, by: item.isActive ? 1 : 3600)) { context in
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
                actions(now: context.date)
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
    private func actions(now: Date) -> some View {
        HStack(spacing: Spacing.tight) {
            if item.isActive {
                // Un transfert qui n'avance plus se coupe et se reprend depuis son partiel, sans rien effacer.
                if queue.canRestart(item.id, now: now) {
                    iconButton("arrow.clockwise", help: "Relancer : coupe la connexion et reprend où le transfert s'est arrêté") { queue.restart(item.id, now: now) }
                }
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

/// Un fichier distant ouvert dans l'éditeur : ce qui s'est passé, et ce que l'utilisateur peut y faire.
struct EditRow: View {
    let session: EditSession
    let edits: EditCoordinator
    let askDiscard: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.regular) {
            Image(systemName: session.needsAttention ? "pencil.circle.fill" : "pencil.circle")
                .font(.system(size: 17))
                .foregroundStyle(session.needsAttention ? Palette.alert : Palette.accentInk)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Spacing.tight) {
                    Text(session.name)
                        .font(TypeScale.body)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(session.connectionName)
                        .font(TypeScale.caption)
                        .foregroundStyle(Palette.inkFaint)
                        .lineLimit(1)
                }
                Text(session.phrase())
                    .font(TypeScale.label)
                    .foregroundStyle(session.needsAttention ? Palette.alert : Palette.inkSoft)
                    .lineLimit(2)
                if session.state == .downloading || session.state == .uploading {
                    ThinProgress(fraction: fraction)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: Spacing.tight)
            actions
        }
        .padding(.horizontal, Spacing.page).padding(.vertical, 8)
    }

    private var fraction: Double? {
        guard session.state == .downloading, let total = session.totalBytes, total > 0 else { return nil }
        return min(1, Double(session.downloadedBytes) / Double(total))
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: Spacing.regular) {
            switch session.state {
            case .downloading:
                Button("Annuler") { edits.discard(session.id) }
            case .editing:
                Button("Rouvrir") { edits.reopen(session.id) }
                Button("Terminer") { Task { await edits.finish(session.id) } }
                    .help("Envoie un dernier enregistrement s'il y en a un, puis supprime la copie locale.")
            case .uploading:
                EmptyView()
            case .conflict:
                Button("Écraser") { edits.overwrite(session.id) }
                    .help("Remplace la version du serveur par la tienne.")
                reveal
                Button("Abandonner…", action: askDiscard)
            case .failed:
                Button("Réessayer") { edits.retry(session.id) }
                reveal
                Button("Abandonner…", action: askDiscard)
            }
        }
        .buttonStyle(QuietButtonStyle())
    }

    private var reveal: some View {
        Button("Afficher") { NSWorkspace.shared.activateFileViewerSelecting([session.localURL]) }
            .help("Montre ta copie dans le Finder.")
    }
}
