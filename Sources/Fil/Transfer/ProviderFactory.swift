import Foundation

enum ProviderFactory {
    /// `password` sert à FTP et WebDAV. SFTP le relit lui-même dans le Keychain via `SSH_ASKPASS`.
    static func make(for connection: RemoteConnection, password: String) -> any RemoteFileProvider {
        switch connection.protocol {
        #if os(macOS)
        case .ftp, .ftps:
            return FTPProvider(connection: connection, password: password)
        case .sftp:
            return SFTPProvider(connection: connection)
        #else
        // Sur iOS, ni libcurl ni ssh : `RemoteProtocol.unavailableReason` le dit avant d'arriver ici.
        case .ftp, .ftps, .sftp:
            return PlannedProvider(connection: connection)
        #endif
        case .webdav, .kdrive:
            return WebDAVProvider(connection: connection, password: password)
        case .protonDrive:
            #if os(macOS)
            return ProtonDriveProvider(connection: connection)
            #else
            return PlannedProvider(connection: connection)
            #endif
        }
    }
}
