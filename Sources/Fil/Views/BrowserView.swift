import SwiftUI
import UniformTypeIdentifiers

/// Une proposition de l'application sur la connexion ouverte (passer en FTPS).
struct SecurityOffer {
    let text: String
    let acceptLabel: String
    let accept: () -> Void
    let dismissLabel: String
    let dismiss: () -> Void
}

/// Phase « fichiers » : naviguer, télécharger, envoyer par glisser-déposer.
struct BrowserView: View {
    @Bindable var browser: BrowserModel
    var offer: SecurityOffer?
    let close: () -> Void

    @State private var sortOrder = [KeyPathComparator(\RemoteFile.name)]
    @State private var isDropTargeted = false
    @State private var isImporting = false
    @State private var pendingDeletion: [RemoteFile] = []
    @State private var pendingUpload: [URL] = []
    @State private var isNamingFolder = false
    @State private var folderName = ""
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            toolbar.padding(.top, Spacing.regular)
            if let offer {
                OfferBanner(text: offer.text, accept: (offer.acceptLabel, offer.accept), dismiss: (offer.dismissLabel, offer.dismiss))
                    .padding(.top, Spacing.tight)
            }
            if let notice = browser.notice {
                AlertBanner(text: notice, action: ("Fermer", { browser.notice = nil }))
                    .padding(.top, Spacing.tight)
            }
            content
                .padding(.top, Spacing.tight)
            footer.padding(.top, Spacing.tight)
        }
        .padding(.horizontal, Spacing.page).padding(.top, Spacing.page).padding(.bottom, 18)
        .dropDestination(for: URL.self) { urls, _ in
            let local = urls.filter { $0.isFileURL && !DragCache.contains($0) }
            requestUpload(local)
            return !local.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { requestUpload(urls) }
        }
        .confirmationDialog(deletionTitle, isPresented: isPresenting($pendingDeletion)) {
            Button("Supprimer", role: .destructive) { browser.delete(pendingDeletion) }
        } message: {
            Text(pendingDeletion.contains(where: \.isDirectory)
                 ? "Les dossiers sont supprimés avec tout leur contenu. Le serveur n'a pas de corbeille."
                 : "Le serveur n'a pas de corbeille : la suppression est définitive.")
        }
        .confirmationDialog(uploadTitle, isPresented: isPresenting($pendingUpload)) {
            Button("Remplacer") { browser.upload(pendingUpload) }
        } message: {
            Text("Ils existent déjà dans « \(browser.title) ». Les fichiers en conflit seront remplacés.")
        }
        .alert("Nouveau dossier", isPresented: $isNamingFolder) {
            TextField("Nom du dossier", text: $folderName)
            Button("Créer") { browser.createFolder(named: folderName) }
                .disabled(browser.folderNameProblem(folderName) != nil)
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(browser.folderNameProblem(folderName) ?? "Dans « \(browser.title) ».")
        }
        .alert(renamingTitle, isPresented: Binding(get: { browser.renaming != nil }, set: { if !$0 { browser.renaming = nil } })) {
            TextField("Nouveau nom", text: $newName)
            Button("Renommer") {
                if let file = browser.renaming { browser.rename(file, to: newName) }
            }
            .disabled(browser.renaming.map { browser.renameProblem($0, to: newName) != nil } ?? true)
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(browser.renaming.flatMap { browser.renameProblem($0, to: newName) } ?? "Dans « \(browser.title) ».")
        }
        .onChange(of: browser.renaming) { _, file in
            if let file { newName = file.name }
        }
        .onChange(of: sortOrder) { _, order in
            guard let first = order.first else { return }
            switch first.keyPath {
            case \RemoteFile.sortableSize: browser.sortKey = .size
            case \RemoteFile.sortableDate: browser.sortKey = .modified
            default: browser.sortKey = .name
            }
            browser.ascending = first.order == .forward
        }
    }

    // MARK: Entête

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                trail
                Spacer()
                Button("Fermer la connexion", action: close)
                    .buttonStyle(QuietButtonStyle())
            }
            Text(browser.title)
                .font(TypeScale.display)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, Spacing.tight)
        }
    }

    /// Fil d'Ariane cliquable ; au-delà de quatre niveaux, le milieu se replie.
    private var trail: some View {
        let lineage = browser.path.lineage
        let shown = lineage.count > 5 ? [lineage[0]] + lineage.suffix(4) : lineage
        return HStack(spacing: 4) {
            Text("Fil ·").foregroundStyle(Palette.inkSoft)
            ForEach(Array(shown.enumerated()), id: \.element) { index, path in
                if index > 0 {
                    Text(index == 1 && lineage.count > 5 ? "› … ›" : "›").foregroundStyle(Palette.inkFaint)
                }
                Button(path.isRoot ? browser.connection.name : path.name) { browser.navigate(to: path) }
                    .buttonStyle(QuietButtonStyle(tint: path == browser.path ? Palette.ink : Palette.inkSoft))
                    .lineLimit(1)
            }
        }
        .font(TypeScale.label)
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            Button { browser.goUp() } label: { Label("Remonter", systemImage: "arrow.up") }
                .disabled(!browser.canGoUp)
            Button { browser.refresh() } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
            Button {
                folderName = ""
                isNamingFolder = true
            } label: { Label("Nouveau dossier", systemImage: "folder.badge.plus") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button { isImporting = true } label: { Label("Envoyer…", systemImage: "square.and.arrow.up") }
                .keyboardShortcut("u")
            Spacer(minLength: Spacing.regular)
            TextField("Filtrer", text: $browser.filter)
                .textFieldStyle(FieldStyle())
                .frame(maxWidth: 200)
        }
        .buttonStyle(ToolButtonStyle())
    }

    // MARK: Contenu

    @ViewBuilder
    private var content: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.large).fill(Palette.surface)
            switch browser.status {
            case .failed(let reason):
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    AlertBanner(text: reason, action: ("Réessayer", { browser.refresh() }))
                    if browser.canGoUp {
                        Button("Revenir au dossier parent") { browser.goUp() }.buttonStyle(QuietButtonStyle())
                    }
                    Spacer()
                }
                .padding(Spacing.regular)
            case .loading where browser.files.isEmpty:
                WaitingLine(text: browser.waitingPhrase ?? "Lecture…")
            default:
                if browser.files.isEmpty {
                    emptyMessage("Ce dossier est vide. Dépose des fichiers ici pour les envoyer.")
                } else if browser.visibleFiles.isEmpty {
                    emptyMessage("Aucun élément ne correspond à « \(browser.filter) ».")
                } else {
                    table
                }
            }
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Radius.large)
                    .strokeBorder(Palette.accentInk, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Palette.accentWash.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.large))
                    .overlay {
                        Label("Déposer pour envoyer dans « \(browser.title) »", systemImage: "arrow.up.doc")
                            .font(TypeScale.bodyStrong)
                            .foregroundStyle(Palette.accentInk)
                    }
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.large))
        .overlay(RoundedRectangle(cornerRadius: Radius.large).stroke(Palette.hairline))
    }

    private var table: some View {
        Table(of: RemoteFile.self, selection: $browser.selection, sortOrder: $sortOrder) {
            TableColumn("Nom", value: \.name) { file in
                HStack(spacing: Spacing.tight) {
                    Image(systemName: icon(for: file))
                        .foregroundStyle(Palette.accentInk)
                        .frame(width: 16)
                    Text(file.name)
                        .font(TypeScale.body)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            TableColumn("Taille", value: \.sortableSize) { file in
                Text(file.byteCount.map(Format.bytes) ?? "—")
                    .font(TypeScale.figures)
                    .foregroundStyle(Palette.inkFaint)
            }
            .width(min: 70, ideal: 90, max: 130)
            TableColumn("Modifié", value: \.sortableDate) { file in
                Text(file.modifiedAt.map { Format.date($0) } ?? "—")
                    .font(TypeScale.label)
                    .foregroundStyle(Palette.inkFaint)
            }
            .width(min: 110, ideal: 150, max: 200)
        } rows: {
            ForEach(browser.visibleFiles) { file in
                // Glisser une ligne vers le Finder la télécharge là où elle est déposée.
                TableRow(file).itemProvider { browser.dragItem(for: file) }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
            let chosen = browser.visibleFiles.filter { ids.contains($0.id) }
            if chosen.count == 1, let only = chosen.first, only.kind != .file {
                Button("Ouvrir") { browser.open(ids) }
            }
            if chosen.count == 1, let only = chosen.first, only.kind == .file {
                Button("Modifier") { browser.edit(only) }
            }
            Button(chosen.count > 1 ? "Télécharger \(Format.items(chosen.count))" : "Télécharger") { browser.download(chosen) }
                .disabled(chosen.isEmpty)
            if chosen.count == 1, let only = chosen.first {
                Button("Renommer…") { browser.renaming = only }
            }
            Button("Copier le chemin") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chosen.map(\.path.value).joined(separator: "\n"), forType: .string)
            }
            .disabled(chosen.isEmpty)
            Divider()
            Button("Supprimer…", role: .destructive) { pendingDeletion = chosen }
                .disabled(chosen.isEmpty)
        } primaryAction: { ids in
            browser.open(ids)
        }
        .onDeleteCommand {
            if !browser.selectedFiles.isEmpty { pendingDeletion = browser.selectedFiles }
        }
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text)
            .font(TypeScale.body)
            .foregroundStyle(Palette.inkSoft)
            .multilineTextAlignment(.center)
            .padding(Spacing.loose)
    }

    private func icon(for file: RemoteFile) -> String {
        switch file.kind {
        case .directory: file.isSymbolicLink ? "folder.badge.questionmark" : "folder"
        case .link: "arrow.turn.down.right"
        case .file: "doc"
        }
    }

    // MARK: Pied

    private var footer: some View {
        HStack(spacing: Spacing.regular) {
            if let phrase = browser.waitingPhrase, !(browser.status == .loading && browser.files.isEmpty) {
                WaitingLine(text: phrase)
            } else {
                Text(browser.footnote)
                    .font(TypeScale.label)
                    .foregroundStyle(Palette.inkFaint)
            }
            Spacer()
            Button("Télécharger") { browser.downloadSelection() }
                .buttonStyle(AccentButtonStyle())
                .disabled(browser.selectedFiles.isEmpty)
                .help("Télécharge la sélection dans le dossier de téléchargement.")
        }
    }

    // MARK: Confirmations

    private func requestUpload(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if browser.conflicts(for: urls).isEmpty {
            browser.upload(urls)
        } else {
            pendingUpload = urls
        }
    }

    private var deletionTitle: String {
        pendingDeletion.count == 1 ? "Supprimer « \(pendingDeletion[0].name) » ?" : "Supprimer \(Format.items(pendingDeletion.count)) ?"
    }

    private var renamingTitle: String {
        browser.renaming.map { "Renommer « \($0.name) »" } ?? "Renommer"
    }

    private var uploadTitle: String {
        let conflicts = browser.conflicts(for: pendingUpload)
        return conflicts.count == 1 ? "Remplacer « \(conflicts[0]) » ?" : "Remplacer \(Format.items(conflicts.count)) ?"
    }

    private func isPresenting<Item>(_ items: Binding<[Item]>) -> Binding<Bool> {
        Binding(get: { !items.wrappedValue.isEmpty }, set: { if !$0 { items.wrappedValue = [] } })
    }
}

/// Clés de tri pour les colonnes ; l'ordre réel (dossiers d'abord) est décidé par `BrowserModel`.
extension RemoteFile {
    var sortableSize: Int64 { byteCount ?? -1 }
    var sortableDate: Date { modifiedAt ?? .distantPast }
}
