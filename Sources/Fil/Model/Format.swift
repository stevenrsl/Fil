import Foundation

/// Seul passage pour les nombres, tailles, durées et dates affichés.
public enum Format {
    public static let locale = Locale(identifier: "fr_FR")

    public static func count(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    public static func bytes(_ value: Int64) -> String {
        if value == 0 { return "0 octet" }
        return value.formatted(.byteCount(style: .file).locale(locale))
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        bytes(Int64(max(0, bytesPerSecond))) + "/s"
    }

    /// « 12 Mo sur 40 Mo ».
    public static func progress(_ done: Int64, of total: Int64) -> String {
        "\(bytes(done)) sur \(bytes(total))"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 1 else { return "moins d'une seconde" }
        let rounded = Int(seconds.rounded())
        return Duration.seconds(rounded).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
                .locale(locale)
        )
    }

    /// Date courte : « 3 oct. à 06:00 » cette année, « 3 oct. 2025 » sinon.
    public static func date(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(locale))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
    }

    /// « 14:32 ».
    public static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(locale))
    }

    /// Le français garde le singulier pour 0 et 1.
    public static func plural(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(count(value)) \(abs(value) <= 1 ? singular : plural)"
    }

    public static func items(_ value: Int) -> String { plural(value, "élément", "éléments") }
    public static func files(_ value: Int) -> String { plural(value, "fichier", "fichiers") }
}
