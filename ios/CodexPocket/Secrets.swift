import Foundation
import Security
import Crypto

// ThisDeviceOnly: credentials do not sync to iCloud or migrate through backups.
enum Secrets {
    static func read(_ name: String) throws -> Data? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "dev.codexpocket.credentials",
            kSecAttrAccount: name,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PocketError("钥匙串读取失败：\(status)") }
        return item as? Data
    }
    static func write(_ data: Data, name: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "dev.codexpocket.credentials",
            kSecAttrAccount: name
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData] = data
            insertion[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let add = SecItemAdd(insertion as CFDictionary, nil)
            guard add == errSecSuccess else { throw PocketError("钥匙串保存失败：\(add)") }
        } else if status != errSecSuccess { throw PocketError("钥匙串更新失败：\(status)") }
    }
    static func deviceKey() throws -> Curve25519.Signing.PrivateKey {
        if let data = try read("device-ed25519") {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        let key = Curve25519.Signing.PrivateKey()
        try write(key.rawRepresentation, name: "device-ed25519")
        return key
    }
    static func publicKey() throws -> String {
        let key = try deviceKey()
        func sshField(_ data: Data) -> Data {
            var length = UInt32(data.count).bigEndian
            return withUnsafeBytes(of: &length) { Data($0) } + data
        }
        let blob = sshField(Data("ssh-ed25519".utf8)) + sshField(key.publicKey.rawRepresentation)
        return "ssh-ed25519 \(blob.base64EncodedString()) codex-pocket-iphone"
    }
    static func passwordName(_ profile: ServerProfile) -> String {
        "password:\(profile.username)@\(profile.host):\(profile.port)"
    }
}
