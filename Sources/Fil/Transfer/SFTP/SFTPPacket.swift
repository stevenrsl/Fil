import Foundation

/// Format binaire du protocole SFTP version 3 (draft-ietf-secsh-filexfer-02), celui d'OpenSSH.
enum SFTPPacketType: UInt8 {
    case initialize = 1, version = 2
    case open = 3, close = 4, read = 5, write = 6
    case lstat = 7, fstat = 8, setstat = 9, fsetstat = 10
    case opendir = 11, readdir = 12, remove = 13, mkdir = 14, rmdir = 15
    case realpath = 16, stat = 17, rename = 18, readlink = 19, symlink = 20
    case status = 101, handle = 102, data = 103, name = 104, attrs = 105
    case extended = 200, extendedReply = 201
}

struct SFTPOpenFlags: OptionSet, Sendable {
    let rawValue: UInt32
    static let read = SFTPOpenFlags(rawValue: 0x01)
    static let write = SFTPOpenFlags(rawValue: 0x02)
    static let append = SFTPOpenFlags(rawValue: 0x04)
    static let create = SFTPOpenFlags(rawValue: 0x08)
    static let truncate = SFTPOpenFlags(rawValue: 0x10)
    static let exclusive = SFTPOpenFlags(rawValue: 0x20)
}

struct SFTPAttributes: Equatable, Sendable {
    static let sizeFlag: UInt32 = 0x0000_0001
    static let ownerFlag: UInt32 = 0x0000_0002
    static let permissionsFlag: UInt32 = 0x0000_0004
    static let timesFlag: UInt32 = 0x0000_0008
    static let extendedFlag: UInt32 = 0x8000_0000

    var size: UInt64?
    var uid: UInt32?
    var gid: UInt32?
    var permissions: UInt32?
    var accessTime: UInt32?
    var modificationTime: UInt32?

    var fileType: UInt32? { permissions.map { $0 & 0o170000 } }
    var isDirectory: Bool { fileType == 0o040000 }
    var isSymbolicLink: Bool { fileType == 0o120000 }
    var modifiedAt: Date? { modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

struct SFTPStatus: Equatable, Sendable {
    static let ok: UInt32 = 0
    static let endOfFile: UInt32 = 1
    static let noSuchFile: UInt32 = 2
    static let permissionDenied: UInt32 = 3
    static let failure: UInt32 = 4
    static let badMessage: UInt32 = 5
    static let noConnection: UInt32 = 6
    static let connectionLost: UInt32 = 7
    static let unsupported: UInt32 = 8

    let code: UInt32
    let message: String
}

struct SFTPNameEntry: Equatable, Sendable {
    let filename: String
    let longname: String
    let attributes: SFTPAttributes
}

enum SFTPResponse: Equatable, Sendable {
    case version(UInt32)
    case status(SFTPStatus)
    case handle(Data)
    case data(Data)
    case name([SFTPNameEntry])
    case attributes(SFTPAttributes)
    case extendedReply(Data)
}

enum SFTPWireError: Error, Equatable {
    case truncated
    /// Longueur absurde : presque toujours du texte imprimé par le shell distant avant SFTP.
    case oversized(UInt32)
    case unexpected(UInt8)
}

struct SFTPWriter {
    private(set) var bytes = Data()

    mutating func byte(_ value: UInt8) { bytes.append(value) }

    mutating func uint32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func uint64(_ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func string(_ value: Data) {
        uint32(UInt32(value.count))
        bytes.append(value)
    }

    mutating func string(_ value: String) { string(Data(value.utf8)) }

    mutating func attributes(_ value: SFTPAttributes) {
        var flags: UInt32 = 0
        if value.size != nil { flags |= SFTPAttributes.sizeFlag }
        if value.uid != nil, value.gid != nil { flags |= SFTPAttributes.ownerFlag }
        if value.permissions != nil { flags |= SFTPAttributes.permissionsFlag }
        if value.accessTime != nil, value.modificationTime != nil { flags |= SFTPAttributes.timesFlag }
        uint32(flags)
        if let size = value.size { uint64(size) }
        if let uid = value.uid, let gid = value.gid { uint32(uid); uint32(gid) }
        if let permissions = value.permissions { uint32(permissions) }
        if let atime = value.accessTime, let mtime = value.modificationTime { uint32(atime); uint32(mtime) }
    }
}

struct SFTPReader {
    private let bytes: Data
    private var offset: Int

    init(_ bytes: Data) {
        self.bytes = bytes
        self.offset = bytes.startIndex
    }

    var isAtEnd: Bool { offset >= bytes.endIndex }

    mutating func byte() throws -> UInt8 {
        guard offset < bytes.endIndex else { throw SFTPWireError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func uint32() throws -> UInt32 {
        guard bytes.endIndex - offset >= 4 else { throw SFTPWireError.truncated }
        var value: UInt32 = 0
        for index in offset..<(offset + 4) { value = value << 8 | UInt32(bytes[index]) }
        offset += 4
        return value
    }

    mutating func uint64() throws -> UInt64 {
        let high = try uint32()
        let low = try uint32()
        return UInt64(high) << 32 | UInt64(low)
    }

    mutating func string() throws -> Data {
        let length = Int(try uint32())
        guard bytes.endIndex - offset >= length else { throw SFTPWireError.truncated }
        defer { offset += length }
        return bytes.subdata(in: offset..<(offset + length))
    }

    mutating func text() throws -> String {
        let data = try string()
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    mutating func attributes() throws -> SFTPAttributes {
        let flags = try uint32()
        var attributes = SFTPAttributes()
        if flags & SFTPAttributes.sizeFlag != 0 { attributes.size = try uint64() }
        if flags & SFTPAttributes.ownerFlag != 0 {
            attributes.uid = try uint32()
            attributes.gid = try uint32()
        }
        if flags & SFTPAttributes.permissionsFlag != 0 { attributes.permissions = try uint32() }
        if flags & SFTPAttributes.timesFlag != 0 {
            attributes.accessTime = try uint32()
            attributes.modificationTime = try uint32()
        }
        if flags & SFTPAttributes.extendedFlag != 0 {
            let count = try uint32()
            for _ in 0..<count {
                _ = try string()
                _ = try string()
            }
        }
        return attributes
    }
}

enum SFTPCodec {
    /// Au-delà, ce n'est pas un paquet SFTP légitime (OpenSSH plafonne à 256 Kio).
    static let maximumPacketLength: UInt32 = 4 * 1024 * 1024

    static func packet(_ type: SFTPPacketType, id: UInt32?, body: (inout SFTPWriter) -> Void = { _ in }) -> Data {
        var payload = SFTPWriter()
        payload.byte(type.rawValue)
        if let id { payload.uint32(id) }
        body(&payload)
        var framed = SFTPWriter()
        framed.string(payload.bytes)
        return framed.bytes
    }

    /// Retire du tampon le prochain paquet complet, s'il est arrivé en entier.
    static func nextPacket(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let length = UInt32(buffer[start]) << 24 | UInt32(buffer[start + 1]) << 16 | UInt32(buffer[start + 2]) << 8 | UInt32(buffer[start + 3])
        guard length > 0, length <= maximumPacketLength else { throw SFTPWireError.oversized(length) }
        guard buffer.count >= 4 + Int(length) else { return nil }
        let payload = buffer.subdata(in: (start + 4)..<(start + 4 + Int(length)))
        buffer.removeSubrange(start..<(start + 4 + Int(length)))
        return payload
    }

    /// Décode une réponse du serveur. `id` est absent pour `VERSION`.
    static func decode(_ payload: Data) throws -> (id: UInt32?, response: SFTPResponse) {
        var reader = SFTPReader(payload)
        let rawType = try reader.byte()
        guard let type = SFTPPacketType(rawValue: rawType) else { throw SFTPWireError.unexpected(rawType) }
        if type == .version {
            return (nil, .version(try reader.uint32()))
        }
        let id = try reader.uint32()
        switch type {
        case .status:
            let code = try reader.uint32()
            // Les serveurs SFTP v2 n'envoient ni message ni langue.
            let message = reader.isAtEnd ? "" : try reader.text()
            return (id, .status(SFTPStatus(code: code, message: message)))
        case .handle:
            return (id, .handle(try reader.string()))
        case .data:
            return (id, .data(try reader.string()))
        case .name:
            let count = try reader.uint32()
            var entries: [SFTPNameEntry] = []
            entries.reserveCapacity(Int(min(count, 4096)))
            for _ in 0..<count {
                let filename = try reader.text()
                let longname = try reader.text()
                entries.append(SFTPNameEntry(filename: filename, longname: longname, attributes: try reader.attributes()))
            }
            return (id, .name(entries))
        case .attrs:
            return (id, .attributes(try reader.attributes()))
        case .extendedReply:
            var rest = Data()
            while !reader.isAtEnd { rest.append(try reader.byte()) }
            return (id, .extendedReply(rest))
        default:
            throw SFTPWireError.unexpected(rawType)
        }
    }
}
