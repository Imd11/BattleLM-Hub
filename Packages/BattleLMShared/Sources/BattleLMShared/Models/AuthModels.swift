import Foundation

// MARK: - QR Code Payload

/// QR Code Payload
public struct PairingQRPayload: Codable {
    public let deviceId: String
    public let deviceName: String
    public let publicKeyFingerprint: String
    public let endpointWss: String
    public let endpointWsLocal: String?
    public let pairingCode: String
    public let expiresAt: Date
    
    public init(deviceId: String, deviceName: String, publicKeyFingerprint: String,
                endpointWss: String, endpointWsLocal: String? = nil, pairingCode: String, expiresAt: Date) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.publicKeyFingerprint = publicKeyFingerprint
        self.endpointWss = endpointWss
        self.endpointWsLocal = endpointWsLocal
        self.pairingCode = pairingCode
        self.expiresAt = expiresAt
    }
    
    public func toBase64() throws -> String {
        let data = try JSONEncoder().encode(self)
        return data.base64EncodedString()
    }
    
    public static func from(base64: String) throws -> PairingQRPayload {
        guard let data = Data(base64Encoded: base64) else {
            throw AuthError.invalidQRCode
        }
        return try JSONDecoder().decode(PairingQRPayload.self, from: data)
    }
}

// MARK: - First-time Pairing

/// Pairing Request (iOS → Mac)
public struct PairRequest: Codable {
    public let type: String
    public let pairingCode: String
    public let phonePublicKey: String
    public let phoneName: String
    
    public init(pairingCode: String, phonePublicKey: String, phoneName: String) {
        self.type = "pairRequest"
        self.pairingCode = pairingCode
        self.phonePublicKey = phonePublicKey
        self.phoneName = phoneName
    }
}

/// Pairing Response (Mac → iOS)
public struct PairResponse: Codable {
    public let type: String
    public let success: Bool
    public let challenge: String?
    public let error: String?
    
    public init(success: Bool, challenge: String?, error: String?) {
        self.type = "pairResponse"
        self.success = success
        self.challenge = challenge
        self.error = error
    }
}

/// Challenge Response (iOS → Mac)
public struct ChallengeResponse: Codable {
    public let type: String
    public let signature: String
    
    public init(signature: String) {
        self.type = "challengeResponse"
        self.signature = signature
    }
}

/// Pairing Complete (Mac → iOS)
public struct PairComplete: Codable {
    public let type: String
    public let macDeviceId: String
    public let macDeviceName: String
    
    public init(macDeviceId: String, macDeviceName: String) {
        self.type = "pairComplete"
        self.macDeviceId = macDeviceId
        self.macDeviceName = macDeviceName
    }
}

// MARK: - Re-authentication (Paired Devices)

/// Reconnect Auth Hello (iOS → Mac)
public struct AuthHello: Codable {
    public let type: String
    public let phonePublicKey: String
    public let phoneName: String
    
    public init(phonePublicKey: String, phoneName: String) {
        self.type = "authHello"
        self.phonePublicKey = phonePublicKey
        self.phoneName = phoneName
    }
}

/// Reconnect Auth Challenge (Mac → iOS)
public struct AuthChallenge: Codable {
    public let type: String
    public let challenge: String
    
    public init(challenge: String) {
        self.type = "authChallenge"
        self.challenge = challenge
    }
}

/// Reconnect Auth Response (iOS → Mac)
public struct AuthResponse: Codable {
    public let type: String
    public let phonePublicKey: String
    public let signature: String
    
    public init(phonePublicKey: String, signature: String) {
        self.type = "authResponse"
        self.phonePublicKey = phonePublicKey
        self.signature = signature
    }
}

/// Auth Success (Mac → iOS)
public struct AuthOK: Codable {
    public let type: String
    
    public init() {
        self.type = "authOK"
    }
}

/// Auth Failed (Mac → iOS)
public struct AuthDenied: Codable {
    public let type: String
    public let error: String
    
    public init(error: String) {
        self.type = "authDenied"
        self.error = error
    }
}

// MARK: - Errors

public enum AuthError: Error, LocalizedError {
    case invalidQRCode
    case expired
    case invalidPairingCode
    case challengeFailed
    case notAuthorized
    
    public var errorDescription: String? {
        switch self {
        case .invalidQRCode: return "Invalid QR code"
        case .expired: return "Pairing code expired"
        case .invalidPairingCode: return "Invalid pairing code"
        case .challengeFailed: return "Authentication failed"
        case .notAuthorized: return "Device not authorized. Please scan again to pair."
        }
    }
}
