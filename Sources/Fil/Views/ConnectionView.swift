import SwiftUI

/// Phases « choisir » et « échec » : régler la connexion, lire la raison, se connecter.
struct ConnectionView: View {
    @Bindable var model: AppModel
    @State private var confirmingDeletion = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let connection = model.selectedConnection {
                    editor(connection)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: Spacing.pageWidth, alignment: .leading)
            .padding(.horizontal, Spacing.page).padding(.top, Spacing.page).padding(.bottom, 64)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Connexions", lede: "Un accès rapide à tes serveurs, sans bruit autour des fichiers.") {
                PageTrail(text: "Fil")
            }
            Divider().overlay(Palette.hairline).padding(.top, 34)
            Text("Ajoute un serveur FTP, SFTP ou WebDAV pour commencer. Tu peux coller une adresse complète, comme sftp://moi@exemple.fr.")
                .font(TypeScale.body)
                .foregroundStyle(Palette.inkSoft)
                .padding(.top, Spacing.loose)
            Button("Ajouter une connexion") { model.addConnection() }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.top, Spacing.regular)
        }
    }

    private func editor(_ connection: RemoteConnection) -> some View {
        let id = connection.id
        let readiness = model.readiness
        return VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                title: connection.name.isEmpty ? "Sans nom" : connection.name,
                lede: connection.resolvedHost.isEmpty ? "Renseigne le serveur ; Fil s'occupe du reste." : connection.summary
            ) {
                HStack(alignment: .firstTextBaseline) {
                    PageTrail(text: "Fil · Connexions")
                    Spacer()
                    Button {
                        model.toggleFavorite(id)
                    } label: {
                        Label(connection.isFavorite ? "Favori" : "Ajouter aux favoris", systemImage: connection.isFavorite ? "star.fill" : "star")
                    }
                    .buttonStyle(QuietButtonStyle(tint: connection.isFavorite ? Palette.accentInk : Palette.inkSoft))
                    .help(connection.isFavorite ? "Retirer des favoris." : "Épingle cette connexion en haut de la liste, avec un raccourci ⌘1 à ⌘9.")
                }
            }

            Divider().overlay(Palette.hairline).padding(.top, 34)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow {
                    fieldLabel("Nom")
                    TextField("Nom affiché", text: binding(id, \.name, connection))
                        .textFieldStyle(FieldStyle())
                }
                GridRow {
                    fieldLabel("Protocole")
                    Picker("Protocole", selection: Binding(
                        get: { connection.protocol },
                        set: { model.updateProtocol(id, to: $0) }
                    )) {
                        ForEach(RemoteProtocol.allCases) { proto in
                            Text(proto.isAvailable ? proto.label : "\(proto.label) (bientôt)").tag(proto)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    fieldLabel(connection.protocol == .kdrive ? "kDrive" : "Adresse")
                    HStack(spacing: Spacing.regular) {
                        TextField(hostPlaceholder(connection.protocol), text: Binding(
                            get: { connection.host },
                            set: { model.updateHost(id, to: $0) }
                        ))
                        .textFieldStyle(FieldStyle())
                        .onSubmit { model.commitHost(id) }
                        Text("Port").font(TypeScale.label).foregroundStyle(Palette.inkSoft)
                        TextField("Port", value: binding(id, \.port, connection), format: .number.grouping(.never))
                            .textFieldStyle(FieldStyle())
                            .frame(width: 76)
                    }
                }
                GridRow {
                    fieldLabel(connection.protocol == .kdrive ? "E-mail" : "Utilisateur")
                    TextField(userPlaceholder(connection.protocol), text: binding(id, \.username, connection))
                        .textFieldStyle(FieldStyle())
                }
                GridRow {
                    fieldLabel("Mot de passe")
                    HStack(spacing: Spacing.regular) {
                        SecureField(passwordPlaceholder(connection.protocol), text: $model.passwordDraft)
                            .textFieldStyle(FieldStyle())
                            .onSubmit { model.connect() }
                        if model.hasSavedPassword {
                            Button("Oublier") { model.forgetPassword(id) }
                                .buttonStyle(QuietButtonStyle())
                                .help("Retire ce mot de passe du trousseau.")
                        }
                    }
                }
                GridRow {
                    fieldLabel(connection.protocol.pathIsRoot ? "Racine" : "Dossier")
                    TextField(pathPlaceholder(connection.protocol), text: binding(id, \.path, connection))
                        .textFieldStyle(FieldStyle())
                }
            }
            .padding(.top, Spacing.loose)

            note(for: connection.protocol)
                .padding(.top, Spacing.regular)

            if let certificate = connection.trustedCertificate {
                HStack(spacing: Spacing.tight) {
                    Label("Certificat approuvé : \(certificate.subject)", systemImage: "checkmark.seal")
                        .font(TypeScale.label)
                        .foregroundStyle(Palette.inkSoft)
                    Text(String(certificate.fingerprint.prefix(23)) + "…")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Palette.inkFaint)
                        .help("Empreinte SHA-256 : \(certificate.fingerprint)")
                    Button("Oublier") { model.forgetCertificate(id) }
                        .buttonStyle(QuietButtonStyle())
                        .help("La prochaine connexion redemandera de vérifier le certificat.")
                }
                .padding(.top, Spacing.tight)
            }

            if case .failed(_, let reason) = model.phase {
                AlertBanner(text: reason)
                    .padding(.top, Spacing.loose)
            }

            HStack(alignment: .center, spacing: Spacing.regular) {
                if let reason = readiness.reason {
                    ReasonLine(text: reason)
                }
                Spacer()
                Button("Se connecter") { model.connect() }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!readiness.isReady)
            }
            .padding(.top, Spacing.loose)

            Divider().overlay(Palette.hairline).padding(.top, 40)
            Button("Supprimer cette connexion…") { confirmingDeletion = true }
                .buttonStyle(QuietButtonStyle(tint: Palette.alert))
                .padding(.top, Spacing.regular)
        }
        .confirmationDialog("Supprimer « \(connection.name) » ?", isPresented: $confirmingDeletion) {
            Button("Supprimer", role: .destructive) { model.deleteConnection(id) }
        } message: {
            Text("Le favori et son mot de passe enregistré seront effacés. Les fichiers du serveur ne sont pas touchés.")
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(TypeScale.label)
            .foregroundStyle(Palette.inkSoft)
            .gridColumnAlignment(.trailing)
    }

    private func binding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<RemoteConnection, Value>, _ fallback: RemoteConnection) -> Binding<Value> {
        Binding(
            get: { (model.connections.first { $0.id == id } ?? fallback)[keyPath: keyPath] },
            set: { value in model.updateConnection(id) { $0[keyPath: keyPath] = value } }
        )
    }

    @ViewBuilder
    private func note(for proto: RemoteProtocol) -> some View {
        switch proto {
        case .ftp:
            Label("FTP n'est pas chiffré : identifiant, mot de passe et fichiers circulent en clair. Préfère FTPS ou SFTP si le serveur le permet.", systemImage: "lock.open")
                .font(TypeScale.label).foregroundStyle(Palette.caution)
        case .ftps:
            noteText("Chiffrement TLS obligatoire. FTPS explicite sur le port 21, implicite sur le port 990. Un certificat que macOS ne reconnaît pas (NAS, serveur personnel) peut être approuvé après vérification de son empreinte.")
        case .sftp:
            noteText("Les clés SSH, l'agent et ~/.ssh/config sont utilisés. Laisse le mot de passe vide si une clé suffit. Le mot de passe passe par le trousseau de macOS. À la première connexion, Fil te montre l'empreinte du serveur pour que tu la vérifies.")
        case .webdav:
            noteText("Connexion HTTPS. La racine est le chemin WebDAV du serveur, par exemple /remote.php/dav/files/moi pour Nextcloud. Un certificat auto-signé peut être approuvé après vérification de son empreinte.")
        case .kdrive:
            noteText("Indique l'identifiant de ton kDrive (les chiffres de son adresse) et ton e-mail Infomaniak. Avec la double authentification, crée un mot de passe d'application.")
        case .protonDrive:
            noteText(proto.unavailableReason ?? "")
        }
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .font(TypeScale.label)
            .foregroundStyle(Palette.inkFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func hostPlaceholder(_ proto: RemoteProtocol) -> String {
        switch proto {
        case .ftp, .ftps: "ftp.exemple.fr"
        case .sftp: "exemple.fr ou un alias de ~/.ssh/config"
        case .webdav: "cloud.exemple.fr"
        case .kdrive: "123456 ou 123456.connect.kdrive.infomaniak.com"
        case .protonDrive: "Indisponible pour l'instant"
        }
    }

    private func userPlaceholder(_ proto: RemoteProtocol) -> String {
        switch proto {
        case .ftp, .ftps: "Vide pour une connexion anonyme"
        case .sftp: "Vide pour l'utilisateur de ~/.ssh/config"
        case .kdrive: "moi@exemple.fr"
        default: "Identifiant"
        }
    }

    private func passwordPlaceholder(_ proto: RemoteProtocol) -> String {
        if model.hasSavedPassword { return "Enregistré dans le trousseau" }
        return proto == .sftp ? "Facultatif avec une clé SSH" : "Mot de passe"
    }

    private func pathPlaceholder(_ proto: RemoteProtocol) -> String {
        proto.pathIsRoot ? "/" : "Dossier personnel"
    }
}
