import SwiftUI

/// Phase « connexion » : une phrase qui évolue avec l'attente, et une sortie.
struct ConnectingView: View {
    let connection: RemoteConnection
    let cancel: () -> Void
    @State private var startedAt = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: connection.name, lede: connection.summary) {
                PageTrail(text: "Fil · Connexion")
            }
            Divider().overlay(Palette.hairline).padding(.top, 34)
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    WaitingLine(text: phrase(elapsed: context.date.timeIntervalSince(startedAt)))
                    if let hint = hint(elapsed: context.date.timeIntervalSince(startedAt)) {
                        Text(hint)
                            .font(TypeScale.label)
                            .foregroundStyle(Palette.inkFaint)
                            .padding(.leading, 26)
                    }
                }
            }
            .padding(.top, Spacing.loose)
            Button("Annuler", action: cancel)
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut(.cancelAction)
                .padding(.top, Spacing.loose)
        }
        .frame(maxWidth: Spacing.pageWidth, alignment: .leading)
        .padding(.horizontal, Spacing.page).padding(.top, Spacing.page)
        .onAppear { startedAt = Date() }
    }

    private func phrase(elapsed: TimeInterval) -> String {
        let host = connection.resolvedHost
        if elapsed < 4 { return "Connexion à \(host) en \(connection.protocol.label)…" }
        return "Toujours en attente de \(host) · \(Format.duration(elapsed))"
    }

    private func hint(elapsed: TimeInterval) -> String? {
        guard elapsed >= 3 else { return nil }
        if connection.protocol == .sftp {
            return "Si macOS demande l'accès au trousseau pour Fil, autorise-le : c'est ainsi que ssh reçoit le mot de passe."
        }
        return elapsed >= 8 ? "Fil abandonne de lui-même si le serveur ne répond pas d'ici une trentaine de secondes." : nil
    }
}
