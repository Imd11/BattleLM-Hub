import Foundation
import Security
import CryptoKit

/// 设备身份管理（Keychain 持久化）
final class DeviceIdentity {
    static let shared = DeviceIdentity()
    
    private let service = "com.battlelm.device"
    
    private init() {}
    
    // MARK: - Device ID
    lazy var deviceId: String = {
        if let existing = loadString(key: "deviceId") {
            return existing
        }
        let newId = UUID().uuidString
        save(key: "deviceId", string: newId)
        return newId
    }()
    
    // MARK: - 签名密钥 (Ed25519，Keychain 持久化)
    lazy var signingKey: Curve25519.Signing.PrivateKey = {
        if let data = loadData(key: "signingKey"),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let newKey = Curve25519.Signing.PrivateKey()
        save(key: "signingKey", data: newKey.rawRepresentation)
        return newKey
    }()
    
    var publicKey: Curve25519.Signing.PublicKey {
        signingKey.publicKey
    }
    
    var publicKeyBase64: String {
        publicKey.rawRepresentation.base64EncodedString()
    }
    
    /// 公钥指纹：SHA256 后取前 8 字节 hex
    var publicKeyFingerprint: String {
        let hash = SHA256.hash(data: publicKey.rawRepresentation)
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    
    /// 签名数据
    func sign(_ data: Data) throws -> Data {
        try signingKey.signature(for: data)
    }
    
    /// 验证签名
    static func verify(signature: Data, for data: Data, publicKeyBase64: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            return false
        }
        return publicKey.isValidSignature(signature, for: data)
    }
    
    // MARK: - Keychain Operations
    private func save(key: String, string: String) {
        save(key: key, data: Data(string.utf8))
    }
    
    private func loadString(key: String) -> String? {
        guard let data = loadData(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    private func save(key: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
    
    private func loadData(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &result)
        return result as? Data
    }
}
