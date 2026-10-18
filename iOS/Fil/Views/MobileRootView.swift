import SwiftUI

/// Une page par phase, et la barre des transferts en bas, visible partout.
struct MobileRootView: View {
    @Bindable var model: AppModel

    var body: some View {
        page
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !model.transfers.items.isEmpty {
                    TransfersBar(queue: model.transfers)
                }
            }
            .tint(Palette.accentInk)
    }

    @ViewBuilder
    private var page: some View {
        switch model.phase {
        case .choosing, .failed:
            ConnectionsPage(model: model)
        case .connecting(let connection):
            ConnectingPage(connection: connection) { model.cancelConnecting() }
        case .confirming(let connection, let request):
            TrustPage(connection: connection, request: request, accept: { model.confirmTrust() }, decline: { model.declineTrust() })
        case .browsing:
            if let browser = model.browser {
                BrowserPage(browser: browser) { model.closeConnection() }
            }
        }
    }
}
