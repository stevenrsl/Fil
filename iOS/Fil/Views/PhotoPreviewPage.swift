import SwiftUI

/// Aperçu plein écran des photos du dossier : balayer pour passer à la voisine, toucher pour masquer
/// les commandes. Le seul bouton plein enregistre la photo dans Fichiers › Fil, sans la retélécharger.
struct PhotoPreviewPage: View {
    @Bindable var model: PhotoPreviewModel
    let downloadFolder: URL
    @Environment(\.dismiss) private var dismiss
    @State private var showsChrome = true

    var body: some View {
        TabView(selection: $model.currentID) {
            ForEach(model.files) { file in
                page(file).tag(file.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Palette.darkroom)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showsChrome.toggle() } }
        .overlay(alignment: .top) {
            if showsChrome { topBar.transition(.opacity) }
        }
        .overlay(alignment: .bottom) {
            if showsChrome { bottomBar.transition(.opacity) }
        }
        .statusBarHidden(!showsChrome)
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: Photo

    @ViewBuilder
    private func page(_ file: RemoteFile) -> some View {
        ZStack {
            Palette.darkroom
            if let image = model.images[file.id] {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(file.name)
            } else {
                switch model.states[file.id] {
                case .failed(let reason):
                    VStack(spacing: Spacing.regular) {
                        Text(reason)
                            .font(TypeScale.body)
                            .foregroundStyle(Palette.onDarkroom)
                            .multilineTextAlignment(.center)
                        Button("Réessayer") { model.retry(file) }
                            .buttonStyle(QuietButtonStyle(tint: Palette.accent))
                    }
                    .padding(Spacing.page)
                default:
                    VStack(spacing: Spacing.regular) {
                        ProgressView().tint(Palette.onDarkroom)
                        Text(loadingPhrase(file))
                            .font(TypeScale.label)
                            .foregroundStyle(Palette.onDarkroom.opacity(0.75))
                            .multilineTextAlignment(.center)
                    }
                    .padding(Spacing.page)
                }
            }
        }
    }

    /// Toute attente a une phrase : la photo entière arrive avant de s'afficher.
    private func loadingPhrase(_ file: RemoteFile) -> String {
        guard case .loading(let received) = model.states[file.id], received > 0 else {
            return "Chargement de « \(file.name) »…"
        }
        let amount = file.byteCount.map { Format.progress(received, of: $0) } ?? Format.bytes(received)
        return "Chargement de « \(file.name) » · \(amount)"
    }

    // MARK: Commandes

    private var topBar: some View {
        HStack(spacing: Spacing.regular) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: Spacing.control, height: Spacing.control)
            }
            .accessibilityLabel("Fermer l'aperçu")
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Text(model.current?.name ?? "")
                    .font(TypeScale.bodyStrong)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.position)
                    .font(TypeScale.caption)
                    .opacity(0.7)
            }
            Spacer(minLength: 0)
            if let file = model.current, let url = model.cachedURL(for: file) {
                // Vers Photos, Messages, AirDrop… : la feuille de partage d'iOS, avec le fichier d'origine.
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: Spacing.control, height: Spacing.control)
                }
                .accessibilityLabel("Partager")
            } else {
                Color.clear.frame(width: Spacing.control, height: Spacing.control)
            }
        }
        .foregroundStyle(Palette.onDarkroom)
        .padding(.horizontal, Spacing.tight)
        .padding(.top, Spacing.tight)
        .background(Palette.darkroom.opacity(0.55).ignoresSafeArea(edges: .top))
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if let file = model.current {
                Text(details(file))
                    .font(TypeScale.label)
                    .foregroundStyle(Palette.onDarkroom.opacity(0.75))
            }
            if let message = model.message {
                Text(message)
                    .font(TypeScale.label)
                    .foregroundStyle(Palette.onDarkroom)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                model.saveCurrent(into: downloadFolder)
            } label: {
                Text("Enregistrer dans Fichiers").frame(maxWidth: .infinity)
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(model.current.flatMap(model.cachedURL(for:)) == nil)
        }
        .padding(.horizontal, Spacing.page)
        .padding(.vertical, Spacing.regular)
        .background(Palette.darkroom.opacity(0.55).ignoresSafeArea(edges: .bottom))
    }

    private func details(_ file: RemoteFile) -> String {
        [file.byteCount.map(Format.bytes), file.modifiedAt.map { Format.date($0) }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
