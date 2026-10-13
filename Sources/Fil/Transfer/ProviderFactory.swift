import Foundation

enum ProviderFactory {
    /// `password` sert à FTP et WebDAV. SFTP le relit lui-même dans le Keychain via `SSH_ASKPASS`.
    static func make(for connection: RemoteConnection, password: String) -> any RemoteFileProvider {
        switch connection.protocol {
        case .ftp, .ftps:
            FTPProvider(connection: connection, password: password)
        case .sftp:
            SFTPProvider(connection: connection)
        case .webdav, .kdrive:
            WebDAVProvider(connection: connection, password: password)
        case .protonDrive:
            PlannedProvider(connection: connection)
        }
    }
}
