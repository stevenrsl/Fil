import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text("Téléchargements")
                .font(TypeScale.section)
                .foregroundStyle(Palette.ink)
            HStack(spacing: Spacing.regular) {
                Image(systemName: "folder")
                    .foregroundStyle(Palette.accentInk)
                Text(FileManager.default.displayName(atPath: model.downloadFolder.path))
                    .font(TypeScale.body)
                    .foregroundStyle(Palette.ink)
                Text(model.downloadFolder.deletingLastPathComponent().path)
                    .font(TypeScale.caption)
                    .foregroundStyle(Palette.inkFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choisir…", action: chooseFolder)
                    .buttonStyle(QuietButtonStyle())
            }
            Text("Les fichiers téléchargés arrivent dans ce dossier. Un nom déjà pris reçoit un numéro : rien n'est écrasé.")
                .font(TypeScale.label)
                .foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Palette.hairline).padding(.vertical, Spacing.tight)

            Text("Modification")
                .font(TypeScale.section)
                .foregroundStyle(Palette.ink)
            HStack(spacing: Spacing.regular) {
                Image(systemName: "pencil")
                    .foregroundStyle(Palette.accentInk)
                Text(model.editorURL.map { FileManager.default.displayName(atPath: $0.path) } ?? "Choisi par macOS")
                    .font(TypeScale.body)
                    .foregroundStyle(Palette.ink)
                Spacer()
                if model.editorURL != nil {
                    Button("Par défaut") { model.editorURL = nil }
                        .buttonStyle(QuietButtonStyle(tint: Palette.inkSoft))
                }
                Button("Choisir…", action: chooseEditor)
                    .buttonStyle(QuietButtonStyle())
            }
            Text("« Modifier » ouvre le fichier distant dans cet éditeur et renvoie chaque enregistrement au serveur. Sans choix, Fil prend l'application de macOS pour ce fichier, ou ton éditeur de texte si c'est un navigateur.")
                .font(TypeScale.label)
                .foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.loose)
        .frame(width: 480)
        .background(Palette.ground)
    }

    private func chooseEditor() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choisir"
        if panel.runModal() == .OK, let url = panel.url {
            model.editorURL = url
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.downloadFolder
        panel.prompt = "Choisir"
        if panel.runModal() == .OK, let url = panel.url {
            model.downloadFolder = url
        }
    }
}
