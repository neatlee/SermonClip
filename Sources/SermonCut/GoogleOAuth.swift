import AppKit
import CryptoKit
import Network

enum GoogleOAuth {
    // youtube.upload covers video/thumbnail uploads; youtube.force-ssl is
    // required for playlistItems.insert when assigning an uploaded video.
    static let scopes = "https://www.googleapis.com/auth/youtube.upload https://www.googleapis.com/auth/youtube.readonly https://www.googleapis.com/auth/youtube.force-ssl"
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw YouTubeFailure(message: "Could not create a secure sign-in request.")
        }
        return base64(Data(bytes))
    }
    static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func challenge(_ verifier: String) -> String { base64(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }
    static func callback(_ target: String, state: String) -> String? {
        guard let url = URLComponents(string: "http://127.0.0.1" + target), url.path == "/oauth",
              url.queryItems?.filter({ $0.name == "state" }).count == 1,
              url.queryItems?.filter({ $0.name == "code" }).count == 1,
              url.queryItems?.first(where: { $0.name == "state" })?.value == state,
              let code = url.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
        return code
    }
}

/// Desktop OAuth callback bound only to loopback, never the LAN.
@MainActor
final class GoogleLoopback {
    private var listener: NWListener?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var completion: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var timeout: Task<Void, Never>?
    private let state: String
    init(state: String) { self.state = state }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.receive(connection) }
        }
        listener.stateUpdateHandler = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .ready:
                    if let port = self.listener?.port?.rawValue { self.ready?.resume(returning: port); self.ready = nil }
                case .failed(let error): self.finish(.failure(error))
                default: break
                }
            }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(YouTubeFailure(message: "Google sign-in timed out. Try connecting again.")))
        }
        return try await withCheckedThrowingContinuation { ready = $0; listener.start(queue: .main) }
    }
    func code() async throws -> String {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { completion = $0 }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ value: Result<String, Error>) {
        guard result == nil else { return }
        result = value
        if case .failure(let error) = value { ready?.resume(throwing: error); ready = nil }
        completion?.resume(with: value); completion = nil
        listener?.cancel(); timeout?.cancel()
    }
    private func receive(_ connection: NWConnection, accumulated: Data = Data()) {
        if accumulated.isEmpty { connection.start(queue: .main) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, ended, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var bytes = accumulated; bytes.append(data ?? Data())
                guard bytes.count <= 8192, error == nil else { connection.cancel(); return }
                let request = String(decoding: bytes, as: UTF8.self)
                guard request.contains("\r\n\r\n") else {
                    if !ended { self.receive(connection, accumulated: bytes) } else { connection.cancel() }
                    return
                }
                let parts = request.components(separatedBy: "\r\n")[0].split(separator: " ")
                let code = parts.count == 3 && parts[0] == "GET" ? GoogleOAuth.callback(String(parts[1]), state: self.state) : nil
                let body = code == nil ? "Sign-in was not accepted. Return to SermonClip and retry." : "Sign-in received. You can return to SermonClip."
                let response = "HTTP/1.1 \(code == nil ? "400 Bad Request" : "200 OK")\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                if let code { self.finish(.success(code)) }
            }
        }
    }
}
