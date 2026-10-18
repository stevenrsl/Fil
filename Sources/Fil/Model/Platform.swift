import Foundation

/// Mots qui désignent l'appareil dans les phrases partagées par macOS et iOS.
public enum Platform {
    #if os(iOS)
    /// « reconnu par iOS ».
    public static let system = "iOS"
    /// « sur cet appareil ».
    public static let device = "cet appareil"
    #else
    public static let system = "macOS"
    public static let device = "ce Mac"
    #endif

    /// « Ce Mac n'est pas connecté… », en tête de phrase.
    public static var deviceCapitalized: String { device.prefix(1).uppercased() + String(device.dropFirst()) }
}
