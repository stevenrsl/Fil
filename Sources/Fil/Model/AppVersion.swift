import Foundation

/// Seule source du numéro de version. `Tools/bundle.sh` la recopie dans l'`Info.plist` du paquet,
/// et un test vérifie que `Support/Info.plist` la suit.
public enum AppVersion {
    /// Version marketing (`CFBundleShortVersionString`), au format `majeure.mineure.correctif`.
    public static let current = "0.1.2"

    /// « Fil 0.1.2 ».
    public static var display: String { "Fil \(current)" }
}
