import AppKit
import SwiftUI

/// Accorde le cadre de la fenêtre au mode choisi : fond de fenêtre aux couleurs de Fil
/// (visible pendant un redimensionnement et derrière la barre de titre transparente), titre masqué.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ view: NSView, context: Context) { (view as? ChromeView)?.apply() }

    private final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = Palette.nsColor(\.ground)
        }
    }
}
