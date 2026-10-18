import SwiftUI

/// Point d'entrée iOS : le même modèle que sur Mac, des pages taillées pour le doigt.
@main
struct FilMobileApp: App {
    @State private var model: AppModel
    /// La file ne garde qu'une référence faible : c'est ici qu'elle vit.
    private let activity: MobileTransferActivity

    init() {
        UploadStaging.purge()
        let model = AppModel()
        let activity = MobileTransferActivity()
        model.transfers.activity = activity
        self.activity = activity
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView(model: model)
        }
    }
}
