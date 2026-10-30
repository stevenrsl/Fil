import CCurl
import Foundation
import os

private let curlGlobalInit: CURLcode = fil_curl_global_init()

/// Drapeau d'annulation partagé entre une tâche Swift et un rappel C de libcurl.
final class CancellationFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { state.withLock { $0 } }
    func cancel() { state.withLock { $0 = true } }
}

/// État d'un `perform` : où vont les octets, d'où ils viennent, à qui rendre compte.
/// Confiné au fil qui exécute le `perform`.
final class CurlTransfer {
    var received = Data()
    let output: FileHandle?
    let input: FileHandle?
    let progress: ProgressHandler?
    let cancellation: CancellationFlag
    var localError: Error?

    init(output: FileHandle? = nil, input: FileHandle? = nil, progress: ProgressHandler? = nil, cancellation: CancellationFlag) {
        self.output = output
        self.input = input
        self.progress = progress
        self.cancellation = cancellation
    }

    /// Erreur d'un appel `read` ou `write` sur le fichier local, dans la forme que `ReadableError` traduit.
    static func fileError(_ code: Int32) -> Error {
        code == ENOSPC ? CocoaError(.fileWriteOutOfSpace) : POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}

/// Échec brut de libcurl, traduit plus haut en phrase lisible.
struct CurlFailure: Error {
    let code: CURLcode
    /// Dernier code de réponse FTP reçu (550, 530…), 0 si aucun.
    let response: Int
    let detail: String
}

/// Poignée libcurl. Une poignée n'est utilisée que par un fil à la fois.
final class CurlHandle {
    private let raw: UnsafeMutableRawPointer
    private let errorBuffer: UnsafeMutablePointer<CChar>
    private var lists: [UnsafeMutablePointer<curl_slist>] = []

    init() throws {
        guard curlGlobalInit == CURLE_OK, let raw = curl_easy_init() else {
            throw ProviderError.server("Le moteur FTP de macOS (libcurl) n'a pas pu démarrer.")
        }
        self.raw = raw
        errorBuffer = .allocate(capacity: Int(CURL_ERROR_SIZE))
        errorBuffer.initialize(to: 0)
    }

    deinit {
        curl_easy_cleanup(raw)
        freeLists()
        errorBuffer.deallocate()
    }

    /// Remet les options à zéro en gardant la connexion ouverte et le cache de session TLS.
    func reset() {
        curl_easy_reset(raw)
        freeLists()
        errorBuffer[0] = 0
        fil_curl_set_pointer(raw, CURLOPT_ERRORBUFFER, errorBuffer)
    }

    func set(_ option: CURLoption, _ value: Int) {
        fil_curl_set_long(raw, option, value)
    }

    func set(_ option: CURLoption, offset value: Int64) {
        fil_curl_set_offset(raw, option, curl_off_t(value))
    }

    func set(_ option: CURLoption, _ value: String) {
        // libcurl copie les chaînes : le pointeur n'a pas à survivre à l'appel.
        value.withCString { _ = fil_curl_set_string(raw, option, $0) }
    }

    func set(_ option: CURLoption, lines: [String]) {
        var list: UnsafeMutablePointer<curl_slist>?
        for line in lines {
            list = curl_slist_append(list, line)
        }
        guard let list else { return }
        lists.append(list)
        fil_curl_set_list(raw, option, list)
    }

    func string(_ info: CURLINFO) -> String? {
        var value: UnsafePointer<CChar>?
        guard fil_curl_get_string(raw, info, &value) == CURLE_OK, let value else { return nil }
        return String(cString: value)
    }

    func long(_ info: CURLINFO) -> Int {
        var value = 0
        _ = fil_curl_get_long(raw, info, &value)
        return value
    }

    func offset(_ info: CURLINFO) -> Int64 {
        var value: curl_off_t = 0
        _ = fil_curl_get_offset(raw, info, &value)
        return Int64(value)
    }

    /// Exécute la requête configurée, en reliant les rappels à `transfer` le temps de l'appel.
    func perform(_ transfer: CurlTransfer) -> Result<Void, CurlFailure> {
        let context = Unmanaged.passUnretained(transfer).toOpaque()
        fil_curl_set_pointer(raw, CURLOPT_WRITEDATA, context)
        fil_curl_set_data_callback(raw, CURLOPT_WRITEFUNCTION) { buffer, size, count, context in
            guard let buffer, let context else { return 0 }
            let transfer = Unmanaged<CurlTransfer>.fromOpaque(context).takeUnretainedValue()
            let length = size * count
            guard let output = transfer.output else {
                transfer.received.append(UnsafeRawPointer(buffer).assumingMemoryBound(to: UInt8.self), count: length)
                return length
            }
            // Directement depuis le tampon de libcurl : ni copie ni allocation par bloc.
            var written = 0
            while written < length {
                let result = Darwin.write(output.fileDescriptor, buffer + written, length - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    transfer.localError = CurlTransfer.fileError(errno)
                    return 0
                }
                written += result
            }
            return length
        }
        if transfer.input != nil {
            fil_curl_set_pointer(raw, CURLOPT_READDATA, context)
            fil_curl_set_data_callback(raw, CURLOPT_READFUNCTION) { buffer, size, count, context in
                guard let buffer, let context else { return Int(CURL_READFUNC_ABORT) }
                let transfer = Unmanaged<CurlTransfer>.fromOpaque(context).takeUnretainedValue()
                guard let input = transfer.input else { return 0 }
                while true {
                    let result = Darwin.read(input.fileDescriptor, buffer, size * count)
                    if result >= 0 { return result }
                    if errno == EINTR { continue }
                    transfer.localError = CurlTransfer.fileError(errno)
                    return Int(CURL_READFUNC_ABORT)
                }
            }
        }
        set(CURLOPT_NOPROGRESS, 0)
        fil_curl_set_pointer(raw, CURLOPT_XFERINFODATA, context)
        fil_curl_set_progress_callback(raw) { context, _, downloaded, _, uploaded in
            guard let context else { return 0 }
            let transfer = Unmanaged<CurlTransfer>.fromOpaque(context).takeUnretainedValue()
            if let progress = transfer.progress {
                progress(Int64(transfer.input == nil ? downloaded : uploaded))
            }
            return transfer.cancellation.isCancelled ? 1 : 0
        }

        let code = withExtendedLifetime(transfer) { curl_easy_perform(raw) }
        guard code != CURLE_OK else { return .success(()) }
        let detail = String(cString: errorBuffer)
        return .failure(CurlFailure(
            code: code,
            response: long(CURLINFO_RESPONSE_CODE),
            detail: detail.isEmpty ? String(cString: curl_easy_strerror(code)) : detail
        ))
    }

    private func freeLists() {
        lists.forEach { curl_slist_free_all($0) }
        lists.removeAll()
    }
}
