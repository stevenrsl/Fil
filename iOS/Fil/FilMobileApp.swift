import SwiftUI

/// Point d'entrée iOS : le même modèle que sur Mac, des pages taillées pour le doigt.
@main
struct FilMobileApp: App {
    @UIApplicationDelegateAdaptor(FilAppDelegate.self) private var appDelegate
    @State private var model: AppModel
    /// La file ne garde qu'une référence faible : c'est ici qu'elle vit.
    private let activity: MobileTransferActivity

    init() {
        UploadStaging.purge()
        PhotoPreviewModel.purgeCache()
        // Sessions d'arrière-plan d'une vie antérieure de Fil : leur file n'existe plus.
        BackgroundSessions.shared.adoptLeftovers()
        let model = AppModel(makeProvider: MobileProviders.make)
        let activity = MobileTransferActivity()
        model.transfers.activity = activity
        BackgroundSessions.shared.onWake = { [weak activity] in activity?.wokeInBackground() }
        self.activity = activity
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView(model: model)
        }
    }
}
