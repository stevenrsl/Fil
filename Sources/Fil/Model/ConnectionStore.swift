import Foundation

/// Favoris versionnés. Aucun secret ici : les mots de passe vivent dans le Keychain.
struct ConnectionStore {
    struct Snapshot: Codable, Equatable {
        var version: Int
        var connections: [RemoteConnection]
        var lastUsedID: UUID?

        init(connections: [RemoteConnection] = [], lastUsedID: UUID? = nil) {
            self.version = ConnectionStore.currentVersion
            self.connections = connections
            self.lastUsedID = lastUsedID
        }
    }

    static let currentVersion = 2
    static let key = "fil.favorites"
    /// Version 1 : tableau nu de connexions, sans enveloppe.
    static let legacyKeyV1 = "fil.connections.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Snapshot {
        if let data = defaults.data(forKey: Self.key),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            return snapshot
        }
        if let data = defaults.data(forKey: Self.legacyKeyV1),
           let connections = try? JSONDecoder().decode([RemoteConnection].self, from: data) {
            let migrated = Snapshot(connections: connections)
            save(migrated)
            defaults.removeObject(forKey: Self.legacyKeyV1)
            return migrated
        }
        return Snapshot()
    }

    func save(_ snapshot: Snapshot) {
        var snapshot = snapshot
        snapshot.version = Self.currentVersion
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Réglages de l'application, hors connexions.
struct Preferences {
    private static let downloadFolderKey = "fil.downloadFolder"
    private static let editorKey = "fil.editor"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// L'application qui ouvre les fichiers à modifier. `nil` : celle que macOS associe au fichier.
    var editorURL: URL? {
        get { defaults.string(forKey: Self.editorKey).map { URL(fileURLWithPath: $0) } }
        nonmutating set { defaults.set(newValue?.path, forKey: Self.editorKey) }
    }

    var downloadFolder: URL {
        get {
            #if os(iOS)
            // Le chemin du conteneur change d'une mise à jour à l'autre : rien à retenir. Documents est
            // ce que l'app Fichiers montre sous « Sur mon iPhone › Fil ».
            return URL.documentsDirectory
            #else
            if let path = defaults.string(forKey: Self.downloadFolderKey) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
            #endif
        }
        nonmutating set { defaults.set(newValue.path, forKey: Self.downloadFolderKey) }
    }
}
