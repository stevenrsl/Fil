import AppKit
import UniformTypeIdentifiers

/// Ouvre un fichier local dans l'éditeur de l'utilisateur.
enum EditorLauncher {
    /// `editor` : l'application choisie dans les réglages. Sans elle, celle que macOS associe au fichier,
    /// sauf si c'est un navigateur : un `.html` s'y afficherait au lieu de s'y modifier. On prend alors
    /// l'éditeur de texte par défaut du système.
    @MainActor
    static func open(_ file: URL, editor: URL?) -> Bool {
        let workspace = NSWorkspace.shared
        if let editor { return open(file, with: editor) }
        if let associated = workspace.urlForApplication(toOpen: file), !isBrowser(associated) {
            return workspace.open(file)
        }
        if let text = workspace.urlForApplication(toOpen: .plainText) {
            return open(file, with: text)
        }
        return workspace.open(file)
    }

    @MainActor
    private static func open(_ file: URL, with application: URL) -> Bool {
        NSWorkspace.shared.open([file], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    /// Une application qui sait ouvrir une adresse web est un navigateur.
    @MainActor
    static func isBrowser(_ application: URL) -> Bool {
        guard let web = URL(string: "https://example.com") else { return false }
        return NSWorkspace.shared.urlsForApplications(toOpen: web).contains { $0.standardizedFileURL.path == application.standardizedFileURL.path }
    }
}
