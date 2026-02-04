import Foundation

// MARK: - QR Code Payload

/// 二维码内容
struct PairingQRPayload: Codable {
    let deviceId: String
    let deviceName: String
    let publicKeyFingerprint: String
    let endpointWss: String
    let endpointWsLocal: String?
    let pairingCode: String
    let expiresAt: Date
    
    func toBase64() throws -> String {
        let data = try JSONEncoder().encode(self)
        return data.base64EncodedString()
    }
    
    static func from(base64: String) throws -> PairingQRPayload {
        guard let data = Data(base64Encoded: base64) else {
            throw AuthError.invalidQRCode
        }
        return try JSONDecoder().decode(PairingQRPayload.self, from: data)
    }
}

// MARK: - First-time Pairing

/// 配对请求 (iOS → Mac)
struct PairRequest: Codable {
    let type: String
    let pairingCode: String
    let phonePublicKey: String
    let phoneName: String
}

/// 配对响应 (Mac → iOS)
struct PairResponse: Codable {
    let type: String
    let success: Bool
    let challenge: String?
    let error: String?
    
    init(success: Bool, challenge: String?, error: String?) {
        self.type = "pairResponse"
        self.success = success
        self.challenge = challenge
        self.error = error
    }
}

/// Challenge 响应 (iOS → Mac)
struct ChallengeResponse: Codable {
    let type: String
    let signature: String
}

/// 配对完成 (Mac → iOS)
struct PairComplete: Codable {
    let type: String
    let macDeviceId: String
    let macDeviceName: String
    
    init(macDeviceId: String, macDeviceName: String) {
        self.type = "pairComplete"
        self.macDeviceId = macDeviceId
        self.macDeviceName = macDeviceName
    }
}

// MARK: - Re-authentication (Paired Devices)

/// 重连认证 Hello (iOS → Mac)
struct AuthHello: Codable {
    let type: String
    let phonePublicKey: String
    let phoneName: String
}

/// 重连认证 Challenge (Mac → iOS)
struct AuthChallenge: Codable {
    let type: String
    let challenge: String
    
    init(challenge: String) {
        self.type = "authChallenge"
        self.challenge = challenge
    }
}

/// 重连认证响应 (iOS → Mac)
struct AuthResponse: Codable {
    let type: String
    let phonePublicKey: String
    let signature: String
}

/// 认证成功 (Mac → iOS)
struct AuthOK: Codable {
    let type: String
    
    init() {
        self.type = "authOK"
    }
}

/// 认证失败 (Mac → iOS)
struct AuthDenied: Codable {
    let type: String
    let error: String
    
    init(error: String) {
        self.type = "authDenied"
        self.error = error
    }
}

// MARK: - Remote Messages

/// 远程事件封装（Mac 维护递增 seq）
struct RemoteEvent: Codable {
    let type: String
    let seq: Int
    let payloadJSON: String
    let timestamp: Date
    
    init(type: String, seq: Int, payloadJSON: String) {
        self.type = type
        self.seq = seq
        self.payloadJSON = payloadJSON
        self.timestamp = Date()
    }
}

/// 发送消息 (iOS → Mac)
struct SendMessagePayload: Codable {
    let type: String
    let aiId: UUID
    let text: String
}

/// AI 状态变更 (Mac → iOS)
struct AIStatusPayload: Codable {
    let aiId: UUID
    let name: String
    let provider: String?
    let isRunning: Bool
    let workingDirectory: String?
}

/// AI 回复 (Mac → iOS)
struct AIResponsePayload: Codable {
    let aiId: UUID
    let message: MessageDTO
    let isStreaming: Bool
}

/// 终端选择提示 (Mac → iOS)
struct TerminalPromptPayload: Codable {
    let aiId: UUID
    let title: String
    let body: String?
    let hint: String?
    let options: [PromptOption]
    
    struct PromptOption: Codable {
        let number: Int
        let label: String
    }
}

/// 终端选择 (iOS → Mac)
struct TerminalChoicePayload: Codable {
    let type: String
    let aiId: UUID
    let choice: Int
}

// MARK: - Group Chats

/// 创建群聊 (iOS → Mac)
struct CreateGroupChatPayload: Codable {
    let type: String
    let name: String
    let memberIds: [UUID]
}

/// 发送群聊消息 (iOS → Mac)
struct SendGroupMessagePayload: Codable {
    let type: String
    let chatId: UUID
    let text: String
}

/// 群聊 DTO（跨平台传输用）
struct GroupChatDTO: Codable, Identifiable {
    let id: UUID
    let name: String
    let memberIds: [UUID]
    let mode: String
    let isActive: Bool
    let messages: [MessageDTO]
}

/// 群聊快照 (Mac → iOS)
struct GroupChatsSnapshotPayload: Codable {
    let chats: [GroupChatDTO]
}

/// 群聊错误 (Mac → iOS)
struct GroupChatErrorPayload: Codable {
    let error: String
}

/// 可序列化消息（跨平台传输用）
struct MessageDTO: Codable, Identifiable {
    let id: UUID
    let senderId: UUID
    let senderType: String
    let senderName: String
    let content: String
    let timestamp: Date
}

// MARK: - Errors

enum AuthError: Error, LocalizedError {
    case invalidQRCode
    case expired
    case invalidPairingCode
    case challengeFailed
    case notAuthorized
    
    var errorDescription: String? {
        switch self {
        case .invalidQRCode: return "Invalid QR code"
        case .expired: return "Pairing code expired"
        case .invalidPairingCode: return "Invalid pairing code"
        case .challengeFailed: return "Authentication failed"
        case .notAuthorized: return "Device not authorized. Please scan again to pair."
        }
    }
}
