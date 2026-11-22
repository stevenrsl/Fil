import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Liste des fichiers distants : un `NSTableView`, pour que le glisser vers le Finder soit une vraie
/// promesse de fichier (`NSFilePromiseProvider`), tenue seulement au dépôt. Les cellules restent en
/// SwiftUI pour garder les jetons de `Design/`. Tri, sélection, menu, Entrée et Suppr suivent le modèle.
struct FileTable: NSViewRepresentable {
    let browser: BrowserModel
    /// Lus dans `body` pour que SwiftUI redessine quand ils changent.
    let files: [RemoteFile]
    let selection: Set<RemoteFile.ID>
    let actions: Actions

    struct Actions {
        var delete: ([RemoteFile]) -> Void
        var rename: (RemoteFile) -> Void
        var upload: ([URL]) -> Void
        var dropTargeted: (Bool) -> Void
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyedTableView()
        table.style = .inset
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.headerView = NSTableHeaderView()
        table.draggingDestinationFeedbackStyle = .none
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([], forLocal: true)
        table.registerForDraggedTypes([.fileURL])

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.sortKey, ascending: true)
            switch column {
            case .name:
                tableColumn.minWidth = 160
                tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
            case .size:
                tableColumn.minWidth = 70; tableColumn.width = 90; tableColumn.maxWidth = 130
            case .modified:
                tableColumn.minWidth = 110; tableColumn.width = 150; tableColumn.maxWidth = 200
            }
            table.addTableColumn(tableColumn)
        }

        let coordinator = context.coordinator
        coordinator.table = table
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.keyHandler = coordinator
        coordinator.update(from: self)
        table.sortDescriptors = [NSSortDescriptor(key: Column.key(for: browser.sortKey), ascending: browser.ascending)]

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }

    // MARK: Colonnes

    enum Column: CaseIterable {
        case name, size, modified

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("fil.\(sortKey)") }
        var title: String {
            switch self {
            case .name: "Nom"
            case .size: "Taille"
            case .modified: "Modifié"
            }
        }
        var sortKey: String {
            switch self {
            case .name: "name"
            case .size: "size"
            case .modified: "modified"
            }
        }

        init?(_ identifier: NSUserInterfaceItemIdentifier?) {
            guard let found = Column.allCases.first(where: { $0.identifier == identifier }) else { return nil }
            self = found
        }

        static func key(for key: BrowserModel.SortKey) -> String {
            switch key {
            case .name: Column.name.sortKey
            case .size: Column.size.sortKey
            case .modified: Column.modified.sortKey
            }
        }

        static func sortKey(for key: String?) -> BrowserModel.SortKey {
            switch key {
            case Column.size.sortKey: .size
            case Column.modified.sortKey: .modified
            default: .name
            }
        }
    }

    // MARK: Coordinateur

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, KeyedTableViewHandler {
        weak var table: NSTableView?
        private var browser: BrowserModel?
        private var actions: Actions?
        private var files: [RemoteFile] = []
        /// Vrai pendant que le modèle pousse sa sélection vers la table : pas d'aller-retour.
        private var isApplyingSelection = false
        private let promises = PromiseSource()

        func update(from representable: FileTable) {
            browser = representable.browser
            actions = representable.actions
            promises.browser = representable.browser
            guard let table else { return }
            if representable.files != files {
                files = representable.files
                table.reloadData()
            }
            let wanted = IndexSet(files.indices.filter { representable.selection.contains(files[$0].id) })
            if wanted != table.selectedRowIndexes {
                isApplyingSelection = true
                table.selectRowIndexes(wanted, byExtendingSelection: false)
                isApplyingSelection = false
            }
        }

        private func file(at row: Int) -> RemoteFile? {
            files.indices.contains(row) ? files[row] : nil
        }

        private var selectedFiles: [RemoteFile] {
            table?.selectedRowIndexes.compactMap(file(at:)) ?? []
        }

        // Données

        func numberOfRows(in tableView: NSTableView) -> Int { files.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            ThemedRowView()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = Column(tableColumn?.identifier), let file = file(at: row) else { return nil }
            let cell = FileCell(file: file, column: column)
            if let reused = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSHostingView<FileCell> {
                reused.rootView = cell
                return reused
            }
            let host = NSHostingView(rootView: cell)
            host.identifier = column.identifier
            return host
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            Column(tableColumn?.identifier) == .name ? file(at: row)?.name : nil
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let browser, let first = tableView.sortDescriptors.first else { return }
            browser.sortKey = Column.sortKey(for: first.key)
            browser.ascending = first.ascending
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let browser, let table else { return }
            browser.selection = Set(table.selectedRowIndexes.compactMap(file(at:)).map(\.id))
        }

        // Glisser vers le Finder : une promesse par ligne, tenue au dépôt.

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard let file = file(at: row), let type = BrowserModel.promisedType(for: file) else { return nil }
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: promises)
            provider.userInfo = PromisedFile(file: file)
            return provider
        }

        // Déposer depuis le Finder : envoi dans le dossier affiché. Une ligne de Fil redéposée sur Fil est refusée.

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard info.draggingSource as? NSTableView !== tableView, !localURLs(in: info).isEmpty else {
                actions?.dropTargeted(false)
                return []
            }
            tableView.setDropRow(-1, dropOperation: .on)
            actions?.dropTargeted(true)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            actions?.dropTargeted(false)
            let urls = localURLs(in: info)
            guard !urls.isEmpty else { return false }
            actions?.upload(urls)
            return true
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            actions?.dropTargeted(false)
        }

        func draggingExited() { actions?.dropTargeted(false) }

        private func localURLs(in info: any NSDraggingInfo) -> [URL] {
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            return urls.filter { !DragCache.contains($0) }
        }

        // Clavier, double-clic, menu

        @objc func doubleClicked(_ sender: NSTableView) {
            guard sender.clickedRow >= 0, let file = file(at: sender.clickedRow) else { return }
            browser?.open([file.id])
        }

        func openSelection() {
            let ids = Set(selectedFiles.map(\.id))
            if !ids.isEmpty { browser?.open(ids) }
        }

        func deleteSelection() {
            let chosen = selectedFiles
            if !chosen.isEmpty { actions?.delete(chosen) }
        }

        func menu(forRow row: Int) -> NSMenu? {
            guard let table, let browser, let actions else { return nil }
            // Comme le Finder : un clic droit hors de la sélection la remplace.
            if row >= 0, !table.selectedRowIndexes.contains(row) {
                table.selectRowIndexes([row], byExtendingSelection: false)
            }
            let chosen = selectedFiles
            guard !chosen.isEmpty else { return nil }
            let menu = NSMenu()
            if chosen.count == 1, let only = chosen.first {
                if only.kind != .file {
                    menu.addItem(ActionItem("Ouvrir") { browser.open([only.id]) })
                } else {
                    menu.addItem(ActionItem("Modifier") { browser.edit(only) })
                }
            }
            menu.addItem(ActionItem(chosen.count > 1 ? "Télécharger \(Format.items(chosen.count))" : "Télécharger") { browser.download(chosen) })
            if chosen.count == 1, let only = chosen.first {
                menu.addItem(ActionItem("Renommer…") { actions.rename(only) })
            }
            menu.addItem(ActionItem("Copier le chemin") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chosen.map(\.path.value).joined(separator: "\n"), forType: .string)
            })
            menu.addItem(.separator())
            menu.addItem(ActionItem("Supprimer…") { actions.delete(chosen) })
            return menu
        }
    }
}

// MARK: Cellules

struct FileCell: View {
    let file: RemoteFile
    let column: FileTable.Column

    var body: some View {
        Group {
            switch column {
            case .name:
                HStack(spacing: Spacing.tight) {
                    Image(systemName: icon)
                        .foregroundStyle(Palette.accentInk)
                        .frame(width: 16)
                    Text(file.name)
                        .font(TypeScale.body)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            case .size:
                Text(file.byteCount.map(Format.bytes) ?? "—")
                    .font(TypeScale.figures)
                    .foregroundStyle(Palette.inkFaint)
            case .modified:
                Text(file.modifiedAt.map { Format.date($0) } ?? "—")
                    .font(TypeScale.label)
                    .foregroundStyle(Palette.inkFaint)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var icon: String {
        switch file.kind {
        case .directory: file.isSymbolicLink ? "folder.badge.questionmark" : "folder"
        case .link: "arrow.turn.down.right"
        case .file: "doc"
        }
    }
}

// MARK: Promesses

/// Ce que porte une promesse : le fichier distant, une valeur.
private final class PromisedFile: NSObject, Sendable {
    let file: RemoteFile
    init(file: RemoteFile) { self.file = file }
}

/// Délégué des promesses. AppKit l'appelle sur sa propre file ; le téléchargement, lui, part sur le
/// fil principal sans le bloquer, et la réponse arrive quand la file des transferts a fini.
private final class PromiseSource: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    /// Écrit sur le fil principal, lu seulement depuis lui.
    weak var browser: BrowserModel?
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Fil.promesses"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? PromisedFile)?.file.name ?? "Fichier"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let file = (filePromiseProvider.userInfo as? PromisedFile)?.file else {
            return completionHandler(CocoaError(.fileWriteUnknown))
        }
        let reply = PromiseReply(completionHandler)
        Task { @MainActor [weak self] in
            guard let browser = self?.browser else { return reply(CancellationError()) }
            browser.deliverPromise(file, to: url) { reply($0) }
        }
    }
}

/// Le rappel d'AppKit n'est pas marqué `Sendable`, mais il est fait pour être appelé une fois, de n'importe quel fil.
private struct PromiseReply: @unchecked Sendable {
    let completion: (Error?) -> Void
    init(_ completion: @escaping (Error?) -> Void) { self.completion = completion }
    func callAsFunction(_ error: Error?) { completion(error) }
}

// MARK: AppKit

@MainActor
protocol KeyedTableViewHandler: AnyObject {
    func openSelection()
    func deleteSelection()
    func menu(forRow row: Int) -> NSMenu?
    func draggingExited()
}

/// Entrée ouvre, Suppr (ou ⌘⌫) demande la suppression, le clic droit vise la ligne cliquée.
/// Ligne dont la sélection prend la couleur du mode (`Palette.selection`), pas l'accent de macOS.
private final class ThemedRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        Palette.nsColor(\.selection).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0), xRadius: Radius.small, yRadius: Radius.small).fill()
    }

    /// Le texte des cellules garde l'encre du mode sur une sélection claire.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

final class KeyedTableView: NSTableView {
    weak var keyHandler: (any KeyedTableViewHandler)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: keyHandler?.openSelection()      // Retour, Entrée
        case 51, 117: keyHandler?.deleteSelection()   // ⌫, ⌦
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return keyHandler?.menu(forRow: row)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        keyHandler?.draggingExited()
    }
}

/// Élément de menu porté par une fermeture.
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("non utilisé") }

    @objc private func run() { handler() }
}
