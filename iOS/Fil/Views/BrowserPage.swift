import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Phase « fichiers » : naviguer, télécharger d'un geste, envoyer depuis l'app Fichiers ou Photos.
/// Toucher un dossier l'ouvre, une photo l'affiche, tout autre fichier se télécharge dans « Sur mon iPhone › Fil ».
struct BrowserPage: View {
    @Bindable var browser: BrowserModel
    let close: () -> Void

    @State private var editMode: EditMode = .inactive
    @State private var isImporting = false
    @State private var isPickingPhotos = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var staging: String?
    @State private var preview: PhotoPreviewModel?
    @State private var pendingDeletion: [RemoteFile] = []
    @State private var pendingUpload: [URL] = []
    @State private var isNamingFolder = false
    @State private var folderName = ""
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(browser.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .searchable(text: $browser.filter, prompt: "Filtrer")
                .safeAreaInset(edge: .top, spacing: 0) { banners }
                .safeAreaInset(edge: .bottom, spacing: 0) { footer }
                .environment(\.editMode, $editMode)
                .background(Palette.ground)
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { stage(urls) }
        }
        // Format d'origine (HEIC, HEVC) : un serveur de fichiers garde ce qu'on lui confie, sans conversion.
        .photosPicker(isPresented: $isPickingPhotos, selection: $photoSelection, maxSelectionCount: nil, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            photoSelection = []
            stagePhotos(items)
        }
        .confirmationDialog(deletionTitle, isPresented: isPresenting($pendingDeletion), titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                browser.delete(pendingDeletion)
                editMode = .inactive
            }
        } message: {
            Text(pendingDeletion.contains(where: \.isDirectory)
                 ? "Les dossiers sont supprimés avec tout leur contenu. Le serveur n'a pas de corbeille."
                 : "Le serveur n'a pas de corbeille : la suppression est définitive.")
        }
        .confirmationDialog(uploadTitle, isPresented: isPresenting($pendingUpload), titleVisibility: .visible) {
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
        .onChange(of: browser.path) { _, _ in
            editMode = .inactive
        }
        .fullScreenCover(item: $preview) { model in
            PhotoPreviewPage(model: model, downloadFolder: Preferences().downloadFolder)
        }
    }

    // MARK: Barre

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if let parent = browser.path.parent {
                Button {
                    browser.goUp()
                } label: {
                    Label(parent.isRoot ? browser.connection.name : parent.name, systemImage: "chevron.backward")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
            } else {
                Button("Fermer", action: close)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if editMode.isEditing {
                Button("OK") { editMode = .inactive }
            } else {
                Menu {
                    Button {
                        isImporting = true
                    } label: { Label("Envoyer des fichiers", systemImage: "square.and.arrow.up") }
                    Button {
                        isPickingPhotos = true
                    } label: { Label("Envoyer des photos", systemImage: "photo.on.rectangle") }
                    Button {
                        folderName = ""
                        isNamingFolder = true
                    } label: { Label("Nouveau dossier", systemImage: "folder.badge.plus") }
                    Button {
                        editMode = .active
                    } label: { Label("Sélectionner", systemImage: "checkmark.circle") }
                    .disabled(browser.files.isEmpty)
                    Picker(selection: $browser.sortKey) {
                        Text("Nom").tag(BrowserModel.SortKey.name)
                        Text("Taille").tag(BrowserModel.SortKey.size)
                        Text("Date de modification").tag(BrowserModel.SortKey.modified)
                    } label: {
                        Label("Trier par", systemImage: "arrow.up.arrow.down")
                    }
                    .pickerStyle(.menu)
                    Toggle("Ordre croissant", isOn: $browser.ascending)
                    Divider()
                    Button {
                        browser.refresh()
                    } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
                    Button(role: .destructive, action: close) {
                        Label("Fermer la connexion", systemImage: "xmark.circle")
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: Contenu

    @ViewBuilder
    private var content: some View {
        switch browser.status {
        case .failed(let reason):
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    AlertBanner(text: reason, action: ("Réessayer", { browser.refresh() }))
                    if browser.canGoUp {
                        Button("Revenir au dossier parent") { browser.goUp() }
                            .buttonStyle(QuietButtonStyle())
                    }
                }
                .padding(Spacing.page)
            }
        case .loading where browser.files.isEmpty:
            WaitingLine(text: browser.waitingPhrase ?? "Lecture…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if browser.files.isEmpty {
                message("Ce dossier est vide. Envoie des fichiers ou des photos depuis le menu en haut à droite.")
            } else if browser.visibleFiles.isEmpty {
                message("Aucun élément ne correspond à « \(browser.filter) ».")
            } else {
                list
            }
        }
    }

    private var list: some View {
        List(selection: $browser.selection) {
            ForEach(browser.visibleFiles) { file in
                row(file)
                    .listRowBackground(Palette.surface)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await refreshed() }
    }

    @ViewBuilder
    private func row(_ file: RemoteFile) -> some View {
        if editMode.isEditing {
            FileRow(file: file)
        } else {
            Button {
                open(file)
            } label: {
                FileRow(file: file)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing) {
                Button("Supprimer", role: .destructive) { pendingDeletion = [file] }
                Button("Renommer") { browser.renaming = file }
                    .tint(Palette.inkSoft)
            }
            .contextMenu {
                if file.kind == .file {
                    if file.isPreviewableImage {
                        Button {
                            open(file)
                        } label: { Label("Aperçu", systemImage: "eye") }
                    }
                    Button {
                        browser.download([file])
                    } label: { Label("Télécharger", systemImage: "arrow.down.circle") }
                } else {
                    Button {
                        browser.open([file.id])
                    } label: { Label("Ouvrir", systemImage: "folder") }
                    Button {
                        browser.download([file])
                    } label: { Label("Télécharger le dossier", systemImage: "arrow.down.circle") }
                }
                Button {
                    browser.renaming = file
                } label: { Label("Renommer…", systemImage: "pencil") }
                Button {
                    UIPasteboard.general.string = file.path.value
                } label: { Label("Copier le chemin", systemImage: "doc.on.doc") }
                Divider()
                Button(role: .destructive) {
                    pendingDeletion = [file]
                } label: { Label("Supprimer…", systemImage: "trash") }
            }
        }
    }

    /// Une photo s'ouvre en aperçu, parmi les photos du dossier dans l'ordre affiché ; le reste suit `BrowserModel.open`.
    private func open(_ file: RemoteFile) {
        guard file.isPreviewableImage else { return browser.open([file.id]) }
        preview = PhotoPreviewModel(files: browser.visibleFiles.filter(\.isPreviewableImage), startingAt: file, provider: browser.provider)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(TypeScale.body)
            .foregroundStyle(Palette.inkSoft)
            .multilineTextAlignment(.center)
            .padding(Spacing.loose)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Tirer pour actualiser : l'indicateur reste tant que le listing n'est pas revenu.
    private func refreshed() async {
        browser.refresh()
        let deadline = Date().addingTimeInterval(30)
        while browser.isRefreshing || browser.status == .loading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Bandeaux et pied

    @ViewBuilder
    private var banners: some View {
        if let notice = browser.notice {
            AlertBanner(text: notice, action: ("Fermer", { browser.notice = nil }))
                .padding(.horizontal, Spacing.page).padding(.vertical, Spacing.tight)
                .background(Palette.ground)
        }
    }

    private var footer: some View {
        HStack(spacing: Spacing.regular) {
            if let phrase = staging ?? waitingPhrase {
                WaitingLine(text: phrase)
            } else {
                Text(browser.footnote)
                    .font(TypeScale.label)
                    .foregroundStyle(Palette.inkFaint)
            }
            Spacer(minLength: Spacing.tight)
            if editMode.isEditing {
                Button("Supprimer") { pendingDeletion = browser.selectedFiles }
                    .buttonStyle(QuietButtonStyle(tint: Palette.alert))
                    .disabled(browser.selectedFiles.isEmpty)
                Button("Télécharger") {
                    browser.downloadSelection()
                    editMode = .inactive
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(browser.selectedFiles.isEmpty)
            }
        }
        .padding(.horizontal, Spacing.page).padding(.vertical, Spacing.tight)
        .frame(minHeight: Spacing.control)
        .background(Palette.ground)
    }

    /// Le chargement initial a déjà sa phrase au milieu de la page.
    private var waitingPhrase: String? {
        guard let phrase = browser.waitingPhrase, !(browser.status == .loading && browser.files.isEmpty) else { return nil }
        return phrase
    }

    // MARK: Envoi

    /// Recopie d'abord les fichiers choisis (voir `UploadStaging`), puis les confie à la file.
    private func stage(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        staging = urls.count == 1 ? "Préparation de « \(urls[0].lastPathComponent) »…" : "Préparation de \(Format.items(urls.count))…"
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try UploadStaging.stage(urls) } }.value
            staging = nil
            switch result {
            case .success(let copies): requestUpload(copies)
            case .failure(let error): browser.notice = ReadableError.message(for: error)
            }
        }
    }

    /// Recopie les photos et vidéos choisies une à une (une vidéo pèse vite plusieurs gigaoctets),
    /// puis les confie à la file comme n'importe quel fichier.
    private func stagePhotos(_ items: [PhotosPickerItem]) {
        staging = items.count == 1 ? "Préparation de l'élément choisi dans Photos…" : "Préparation de \(Format.items(items.count)) choisis dans Photos…"
        Task {
            var copies: [URL] = []
            var unreadable = 0
            var failure: Error?
            for item in items {
                do {
                    if let media = try await item.loadTransferable(type: StagedMedia.self) {
                        copies.append(media.url)
                    } else {
                        unreadable += 1
                    }
                } catch {
                    failure = error
                    unreadable += 1
                }
            }
            do {
                copies = try UploadStaging.distinctNames(copies)
            } catch {
                failure = error
                unreadable += copies.count
                copies = []
            }
            staging = nil
            if unreadable > 0 {
                let what = unreadable == 1 ? "Un élément de Photos n'a pas pu être lu" : "\(Format.count(unreadable)) éléments de Photos n'ont pas pu être lus"
                browser.notice = what + (failure.map { " : \(ReadableError.message(for: $0))" } ?? ".") + (copies.isEmpty ? "" : " Les autres partent.")
            }
            requestUpload(copies)
        }
    }

    private func requestUpload(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if browser.conflicts(for: urls).isEmpty {
            browser.upload(urls)
        } else {
            pendingUpload = urls
        }
    }

    // MARK: Confirmations

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

/// Une ligne de fichier : icône, nom, taille et date.
private struct FileRow: View {
    let file: RemoteFile

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: icon)
                .foregroundStyle(Palette.accentInk)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(TypeScale.body)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !details.isEmpty {
                    Text(details)
                        .font(TypeScale.caption)
                        .foregroundStyle(Palette.inkFaint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if file.kind != .file {
                Image(systemName: "chevron.forward")
                    .font(TypeScale.caption)
                    .foregroundStyle(Palette.inkFaint)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch file.kind {
        case .directory: file.isSymbolicLink ? "folder.badge.questionmark" : "folder"
        case .link: "arrow.turn.down.right"
        case .file: file.isPreviewableImage ? "photo" : "doc"
        }
    }

    private var details: String {
        [file.byteCount.map(Format.bytes), file.modifiedAt.map { Format.date($0) }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
