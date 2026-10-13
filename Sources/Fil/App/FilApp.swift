import AppKit
import SwiftUI

/// Point d'entrée. Le même binaire sert d'assistant `SSH_ASKPASS` quand `ssh` le relance.
@main
enum Main {
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        if let status = Askpass.runIfRequested(environment: environment, arguments: CommandLine.arguments, secrets: KeychainStore()) {
            exit(status)
        }
        // Écrire vers un ssh déjà terminé doit produire une erreur, pas tuer l'application.
        signal(SIGPIPE, SIG_IGN)
        FilApp.main()
    }
}

struct FilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Fil", id: "main") {
            RootView(model: delegate.model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1080, height: 720)
        .commands { FilCommands(model: delegate.model) }

        Settings {
            SettingsView(model: delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lancé par `swift run`, sans paquet .app : sans cela, la fenêtre n'aurait ni Dock ni clavier.
        // Un vrai paquet est activé par macOS ; on ne lui force pas la main.
        guard Bundle.main.bundleIdentifier == nil else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Fermer la fenêtre ne coupe pas les transferts : l'application reste ouverte.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = model.transfers.activeCount
        guard active > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = active == 1 ? "Un transfert est en cours." : "\(Format.count(active)) transferts sont en cours."
        alert.informativeText = "Quitter Fil les interrompt. Les fichiers partiels sont supprimés."
        alert.addButton(withTitle: "Continuer les transferts")
        alert.addButton(withTitle: "Quitter quand même")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        // On laisse aux annulations le temps d'effacer les fichiers partiels, sans s'éterniser.
        model.transfers.cancelAll()
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(3)
            while model.transfers.hasActive, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct FilCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nouvelle connexion") { model.addConnection() }
                .keyboardShortcut("n")
        }
        CommandMenu("Connexion") {
            Button("Se connecter") { model.connect() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.readiness.isReady || model.phase.isConnecting || model.phase.isBrowsing)
            Button("Fermer la connexion") { model.closeConnection() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.browser == nil)
            Divider()
            Button("Actualiser") { model.browser?.refresh() }
                .keyboardShortcut("r")
                .disabled(model.browser == nil)
            Button("Dossier parent") { model.browser?.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model.browser?.canGoUp != true)
            Button("Télécharger la sélection") { model.browser?.downloadSelection() }
                .keyboardShortcut("d")
                .disabled(model.browser?.selectedFiles.isEmpty ?? true)
        }
    }
}
