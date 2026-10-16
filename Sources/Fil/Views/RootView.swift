import SwiftUI

/// Barre latérale des connexions, une page par phase, et le plateau des transferts en bas.
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
            Rectangle().fill(Palette.hairline).frame(width: 1)
            VStack(spacing: 0) {
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if !model.transfers.items.isEmpty || !model.edits.sessions.isEmpty {
                    TransfersTray(queue: model.transfers, edits: model.edits)
                }
            }
            .background(Palette.ground)
        }
        .background(Palette.ground)
    }

    @ViewBuilder
    private var page: some View {
        switch model.phase {
        case .choosing, .failed:
            ConnectionView(model: model)
        case .connecting(let connection):
            ConnectingView(connection: connection) { model.cancelConnecting() }
        case .confirming(let connection, let request):
            TrustView(connection: connection, request: request, accept: { model.confirmTrust() }, decline: { model.declineTrust() })
        case .browsing:
            if let browser = model.browser {
                BrowserView(browser: browser, offer: ftpsOffer) { model.closeConnection() }
            }
        }
    }
}

extension RootView {
    /// FTP en clair alors que le serveur sait faire FTPS : une phrase, deux liens.
    fileprivate var ftpsOffer: SecurityOffer? {
        guard model.hasFTPSOffer else { return nil }
        return SecurityOffer(
            text: "Ce serveur accepte FTPS. En FTP, ton mot de passe et tes fichiers circulent en clair.",
            acceptLabel: "Passer en FTPS",
            accept: { model.acceptFTPSOffer() },
            dismissLabel: "Ne plus proposer",
            dismiss: { model.dismissFTPSOffer() }
        )
    }
}

struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var pendingDeletion: RemoteConnection?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text("Connexions")
                .font(TypeScale.label)
                .foregroundStyle(Palette.inkFaint)
                .padding(.horizontal, 10)
                .padding(.bottom, Spacing.hair)
            if model.connections.isEmpty {
                Text("Aucune connexion")
                    .font(TypeScale.label)
                    .foregroundStyle(Palette.inkSoft)
                    .padding(.horizontal, 10)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.connections) { connection in
                        row(connection)
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                model.addConnection()
            } label: {
                Label("Ajouter une connexion", systemImage: "plus")
            }
            .buttonStyle(QuietButtonStyle())
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, Spacing.tight)
        .frame(width: Spacing.sidebarWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.groundSunk)
        .confirmationDialog(
            "Supprimer « \(pendingDeletion?.name ?? "") » ?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { connection in
            Button("Supprimer", role: .destructive) { model.deleteConnection(connection.id) }
        } message: { _ in
            Text("Le favori et son mot de passe enregistré seront effacés. Les fichiers du serveur ne sont pas touchés.")
        }
    }

    private func row(_ connection: RemoteConnection) -> some View {
        let isSelected = connection.id == model.selectedConnectionID
        let isActive = connection.id == model.activeConnectionID
        return Button {
            model.select(connection.id)
        } label: {
            HStack(spacing: Spacing.tight) {
                ProtocolBadge(proto: connection.protocol, isActive: isActive || isSelected)
                VStack(alignment: .leading, spacing: 1) {
                    Text(connection.name.isEmpty ? "Sans nom" : connection.name)
                        .font(TypeScale.body)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(isActive ? (model.phase.isConnecting ? "Connexion…" : "Ouverte") : (connection.resolvedHost.isEmpty ? connection.protocol.label : connection.resolvedHost))
                        .font(TypeScale.caption)
                        .foregroundStyle(isActive ? Palette.accentInk : Palette.inkFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(isSelected ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.medium))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 3 h du matin : un double-clic suffit pour ouvrir.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.select(connection.id)
            if model.readiness.isReady, model.activeConnectionID != connection.id { model.connect() }
        })
        .contextMenu {
            Button("Se connecter") {
                model.select(connection.id)
                model.connect()
            }
            .disabled(!Readiness.connecting(connection).isReady)
            Divider()
            Button("Supprimer la connexion…", role: .destructive) { pendingDeletion = connection }
        }
    }
}
