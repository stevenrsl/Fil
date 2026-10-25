import SwiftUI

/// Régler une connexion, lire la raison d'un échec, se connecter.
struct ConnectionPage: View {
    @Bindable var model: AppModel
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDeletion = false

    var body: some View {
        Group {
            if let connection = model.connections.first(where: { $0.id == id }) {
                form(connection)
            } else {
                Text("Cette connexion n'existe plus.")
                    .font(TypeScale.body)
                    .foregroundStyle(Palette.inkSoft)
            }
        }
        .background(Palette.ground)
        .onAppear { model.select(id) }
    }

    private func form(_ connection: RemoteConnection) -> some View {
        Form {
            Section {
                TextField("Nom affiché", text: binding(\.name, connection))
                Picker("Protocole", selection: Binding(
                    get: { connection.protocol },
                    set: { model.updateProtocol(id, to: $0) }
                )) {
                    ForEach(RemoteProtocol.allCases) { proto in
                        Text(proto.isAvailable ? proto.label : "\(proto.label) (bientôt)").tag(proto)
                    }
                }
            } footer: {
                note(for: connection.protocol)
            }

            // Un protocole pas encore branché sur iOS ne montre pas de champs à remplir pour rien.
            if connection.protocol.isAvailable {
                Section("Serveur") {
                    TextField(hostPlaceholder(connection.protocol), text: Binding(
                        get: { connection.host },
                        set: { model.updateHost(id, to: $0) }
                    ))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { model.commitHost(id) }
                    LabeledContent("Port") {
                        TextField("Port", value: binding(\.port, connection), format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField(connection.protocol.pathIsRoot ? "Racine WebDAV (/ par défaut)" : "Dossier de départ", text: binding(\.path, connection))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    TextField(connection.protocol == .kdrive ? "moi@exemple.fr" : "Identifiant", text: binding(\.username, connection))
                        .textContentType(.username)
                        .keyboardType(connection.protocol == .kdrive ? .emailAddress : .default)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(model.hasSavedPassword ? "Enregistré dans le trousseau" : "Mot de passe", text: $model.passwordDraft)
                        .textContentType(.password)
                        .onSubmit { model.connect() }
                    if model.hasSavedPassword {
                        Button("Oublier le mot de passe") { model.forgetPassword(id) }
                            .buttonStyle(QuietButtonStyle())
                    }
                } header: {
                    Text(connection.protocol == .kdrive ? "Compte Infomaniak" : "Identifiants")
                }
            }

            if let certificate = connection.trustedCertificate {
                Section("Certificat approuvé") {
                    LabeledContent("Nom", value: certificate.subject)
                    Text(certificate.fingerprint)
                        .font(TypeScale.figures)
                        .foregroundStyle(Palette.inkFaint)
                        .textSelection(.enabled)
                    Button("Oublier ce certificat") { model.forgetCertificate(id) }
                        .buttonStyle(QuietButtonStyle())
                }
            }

            Section {
                Button("Supprimer cette connexion…", role: .destructive) { confirmingDeletion = true }
                    .buttonStyle(QuietButtonStyle(tint: Palette.alert))
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(connection.name.isEmpty ? "Sans nom" : connection.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.toggleFavorite(id)
                } label: {
                    Label(connection.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris", systemImage: connection.isFavorite ? "star.fill" : "star")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            connectBar
        }
        .confirmationDialog("Supprimer « \(connection.name) » ?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                model.deleteConnection(id)
                dismiss()
            }
        } message: {
            Text("La connexion et son mot de passe enregistré seront effacés. Les fichiers du serveur ne sont pas touchés.")
        }
    }

    /// La raison d'un échec ou d'un réglage manquant, au-dessus du seul bouton plein de la page.
    private var connectBar: some View {
        let readiness = model.readiness
        return VStack(alignment: .leading, spacing: Spacing.tight) {
            if case .failed(let failed, let reason) = model.phase, failed.id == id {
                AlertBanner(text: reason)
            } else if let reason = readiness.reason {
                ReasonLine(text: reason)
            }
            Button {
                model.commitHost(id)
                model.connect()
            } label: {
                Text("Se connecter").frame(maxWidth: .infinity)
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(!readiness.isReady)
        }
        .padding(.horizontal, Spacing.page).padding(.vertical, Spacing.regular)
        .background(Palette.ground)
        .overlay(alignment: .top) { Divider().overlay(Palette.hairline) }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<RemoteConnection, Value>, _ fallback: RemoteConnection) -> Binding<Value> {
        Binding(
            get: { (model.connections.first { $0.id == id } ?? fallback)[keyPath: keyPath] },
            set: { value in model.updateConnection(id) { $0[keyPath: keyPath] = value } }
        )
    }

    @ViewBuilder
    private func note(for proto: RemoteProtocol) -> some View {
        switch proto {
        case .webdav:
            Text("Connexion HTTPS. La racine est le chemin WebDAV du serveur, par exemple /remote.php/dav/files/moi pour Nextcloud. Un certificat auto-signé peut être approuvé après vérification de son empreinte.")
        case .kdrive:
            Text("Indique l'identifiant de ton kDrive (les chiffres de son adresse) et ton e-mail Infomaniak. Avec la double authentification, crée un mot de passe d'application.")
        case .ftp, .ftps, .sftp, .protonDrive:
            Text(proto.unavailableReason ?? "")
        }
    }

    private func hostPlaceholder(_ proto: RemoteProtocol) -> String {
        switch proto {
        case .ftp, .ftps: "ftp.exemple.fr"
        case .sftp: "exemple.fr"
        case .webdav: "cloud.exemple.fr"
        case .kdrive: "123456 ou 123456.connect.kdrive.infomaniak.com"
        case .protonDrive: "Aucune adresse : compte Proton Drive"
        }
    }
}
