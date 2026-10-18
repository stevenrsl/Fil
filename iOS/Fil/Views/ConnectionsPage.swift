import SwiftUI

/// Phases « choisir » et « échec » : la liste des connexions, et le réglage de l'une d'elles.
/// Toucher une connexion prête l'ouvre tout de suite ; sinon, ses réglages s'affichent.
struct ConnectionsPage: View {
    @Bindable var model: AppModel
    @State private var path: [UUID]
    @State private var pendingDeletion: RemoteConnection?

    init(model: AppModel) {
        _model = Bindable(model)
        // Un échec ramène sur les réglages de la connexion, avec la raison au-dessus du bouton.
        if case .failed(let connection, _) = model.phase {
            _path = State(initialValue: [connection.id])
        } else {
            _path = State(initialValue: [])
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationTitle("Fil")
                .navigationDestination(for: UUID.self) { id in
                    ConnectionPage(model: model, id: id)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            add()
                        } label: {
                            Label("Ajouter une connexion", systemImage: "plus")
                        }
                    }
                }
        }
        .confirmationDialog(
            "Supprimer « \(pendingDeletion?.name ?? "") » ?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { connection in
            Button("Supprimer", role: .destructive) { model.deleteConnection(connection.id) }
        } message: { _ in
            Text("La connexion et son mot de passe enregistré seront effacés. Les fichiers du serveur ne sont pas touchés.")
        }
    }

    @ViewBuilder
    private var list: some View {
        if model.connections.isEmpty {
            emptyState
        } else {
            List {
                let favorites = model.favoriteConnections
                let others = model.otherConnections
                if !favorites.isEmpty {
                    Section("Favoris") {
                        ForEach(favorites) { row($0) }
                    }
                }
                if !others.isEmpty {
                    Section("Connexions") {
                        ForEach(others) { row($0) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Un accès rapide à tes serveurs, sans bruit autour des fichiers.")
                    .font(TypeScale.lede)
                    .foregroundStyle(Palette.inkSoft)
                Text("Ajoute un serveur WebDAV ou ton kDrive pour commencer. Tu peux coller une adresse complète, comme https://moi@cloud.exemple.fr/dav.")
                    .font(TypeScale.body)
                    .foregroundStyle(Palette.inkSoft)
                    .padding(.top, Spacing.loose)
                Button("Ajouter une connexion", action: add)
                    .buttonStyle(AccentButtonStyle())
                    .padding(.top, Spacing.regular)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.page)
        }
        .background(Palette.ground)
    }

    private func row(_ connection: RemoteConnection) -> some View {
        HStack(spacing: Spacing.regular) {
            Button {
                open(connection)
            } label: {
                HStack(spacing: Spacing.regular) {
                    ProtocolBadge(proto: connection.protocol, isActive: connection.id == model.selectedConnectionID)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.name.isEmpty ? "Sans nom" : connection.name)
                            .font(TypeScale.body)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text(subtitle(connection))
                            .font(TypeScale.caption)
                            .foregroundStyle(Palette.inkFaint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                showSettings(connection)
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Réglages de « \(connection.name) »")
        }
        .listRowBackground(Palette.surface)
        .swipeActions(edge: .trailing) {
            Button("Supprimer", role: .destructive) { pendingDeletion = connection }
        }
        .swipeActions(edge: .leading) {
            Button(connection.isFavorite ? "Retirer" : "Favori") { model.toggleFavorite(connection.id) }
                .tint(Palette.accentInk)
        }
        .contextMenu {
            Button("Se connecter") {
                model.select(connection.id)
                model.connect()
            }
            .disabled(!Readiness.connecting(connection).isReady)
            Button("Réglages") { showSettings(connection) }
            Button(connection.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris") { model.toggleFavorite(connection.id) }
            Button("Supprimer la connexion…", role: .destructive) { pendingDeletion = connection }
        }
    }

    private func subtitle(_ connection: RemoteConnection) -> String {
        if let reason = connection.protocol.unavailableReason { return reason }
        return connection.resolvedHost.isEmpty ? connection.protocol.label : connection.summary
    }

    /// 3 h du matin : une connexion prête s'ouvre d'un geste. S'il manque un réglage ou le mot de passe,
    /// ses réglages s'affichent plutôt qu'un refus du serveur.
    private func open(_ connection: RemoteConnection) {
        model.select(connection.id)
        let needsPassword = !connection.username.isEmpty && !model.savedPasswordIDs.contains(connection.id)
        if model.readiness.isReady, !needsPassword {
            model.connect()
        } else {
            path = [connection.id]
        }
    }

    private func showSettings(_ connection: RemoteConnection) {
        model.select(connection.id)
        path = [connection.id]
    }

    private func add() {
        model.addConnection()
        if let id = model.selectedConnectionID { path = [id] }
    }
}
