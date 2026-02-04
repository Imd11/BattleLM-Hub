import Foundation
import Security

/// 持久化存储已授权的 iOS 设备（Keychain）
class AuthorizedDeviceStore {
    static let shared = AuthorizedDeviceStore()
    
    private let service = "com.battlelm.authorized"
    private let account = "devices"
    
    private init() {}
    
    struct AuthorizedDevice: Codable {
        let publicKey: String
        let name: String
        let authorizedAt: Date
    }
    
    /// 获取所有授权设备
    func loadAll() -> [AuthorizedDevice] {
        guard let data = loadFromKeychain(),
              let devices = try? JSONDecoder().decode([AuthorizedDevice].self, from: data) else {
            return []
        }
        return devices
    }
    
    /// 添加授权设备
    func authorize(publicKey: String, name: String) {
        var devices = loadAll()
        devices.removeAll { $0.publicKey == publicKey }
        devices.append(AuthorizedDevice(publicKey: publicKey, name: name, authorizedAt: Date()))
        saveToKeychain(devices)
    }
    
    /// 检查是否已授权
    func isAuthorized(publicKey: String) -> Bool {
        loadAll().contains { $0.publicKey == publicKey }
    }
    
    /// 获取设备名称
    func getDeviceName(publicKey: String) -> String? {
        loadAll().first { $0.publicKey == publicKey }?.name
    }
    
    /// 撤销授权
    func revoke(publicKey: String) {
        var devices = loadAll()
        devices.removeAll { $0.publicKey == publicKey }
        saveToKeychain(devices)
    }
    
    /// 撤销所有授权
    func revokeAll() {
        saveToKeychain([])
    }
    
    // MARK: - Keychain Operations
    private func loadFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &result)
        return result as? Data
    }
    
    private func saveToKeychain(_ devices: [AuthorizedDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
}
