import Foundation
import Citadel
import Crypto
import NIOSSH

@MainActor
final class SSHBridge {
    private var client: SSHClient?
    private var path = ""
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    func connect(_ profile: ServerProfile, password: String) async throws {
        await disconnect()
        guard !profile.host.isEmpty, !profile.username.isEmpty,
              let port = Int(profile.port), (1...65535).contains(port) else {
            throw PocketError("请填写服务器地址、用户名和有效端口。")
        }
        let publicKey = try NIOSSHPublicKey(openSSHPublicKey: profile.hostPublicKey.trimmingCharacters(in: .whitespacesAndNewlines))
        let key = try Secrets.deviceKey()
        let username = profile.username
        let keyAuth = profile.auth == "key"
        let settings = SSHClientSettings(
            host: profile.host, port: port,
            authenticationMethod: {
                if keyAuth { return .ed25519(username: username, privateKey: key) }
                return .passwordBased(username: username, password: password)
            },
            hostKeyValidator: .trustedKeys([publicKey])
        )
        client = try await SSHClient.connect(to: settings)
        path = profile.bridgePath
    }
    func disconnect() async {
        let old = client
        client = nil
        try? await old?.close()
    }
    func request<T: Decodable>(_ fields: [String: String], as: T.Type) async throws -> T {
        guard let client, client.isConnected else { throw PocketError("SSH 已断开，请返回连接页重新连接。") }
        let payload = try JSONEncoder().encode(fields).base64EncodedString()
        let remotePath: String
        if path.hasPrefix("~/") {
            remotePath = "\"$HOME\"/" + Self.quote(String(path.dropFirst(2)))
        } else {
            guard path.hasPrefix("/") else { throw PocketError("桥接脚本路径必须以 ~/ 或 / 开头。") }
            remotePath = Self.quote(path)
        }
        let command = "python3 \(remotePath) \(Self.quote(payload))"
        let buffer = try await client.executeCommand("bash -lc \(Self.quote(command))", maxResponseSize: 16 * 1024 * 1024)
        // Ignore login banners emitted before the single JSON response.
        let output = String(decoding: buffer.readableBytesView, as: UTF8.self)
        guard let line = output.split(separator: "\n").last else { throw PocketError("服务器没有返回数据。") }
        let envelope = try JSONDecoder().decode(BridgeEnvelope<T>.self, from: Data(line.utf8))
        guard envelope.ok, let result = envelope.data else {
            throw PocketError(envelope.error ?? "服务器操作失败")
        }
        return result
    }
}
