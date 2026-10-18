import SwiftUI

/// Phase « connexion » : une phrase qui évolue avec l'attente, et une sortie.
struct ConnectingPage: View {
    let connection: RemoteConnection
    let cancel: () -> Void
    @State private var startedAt = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: connection.name, lede: connection.summary) {
                PageTrail(text: "Fil · Connexion")
            }
            Divider().overlay(Palette.hairline).padding(.top, Spacing.loose)
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(startedAt)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    WaitingLine(text: phrase(elapsed: elapsed))
                    if elapsed >= 8 {
                        Text("Fil abandonne de lui-même si le serveur ne répond pas d'ici une trentaine de secondes.")
                            .font(TypeScale.label)
                            .foregroundStyle(Palette.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, Spacing.loose)
            Button("Annuler", action: cancel)
                .buttonStyle(QuietButtonStyle())
                .padding(.top, Spacing.loose)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.page)
        .background(Palette.ground)
        .onAppear { startedAt = Date() }
    }

    private func phrase(elapsed: TimeInterval) -> String {
        let host = connection.resolvedHost
        if elapsed < 4 { return "Connexion à \(host) en \(connection.protocol.label)…" }
        return "Toujours en attente de \(host) · \(Format.duration(elapsed))"
    }
}
