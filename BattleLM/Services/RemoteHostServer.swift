import Foundation
import Network
import CryptoKit
import Combine
import SystemConfiguration

/// macOS WebSocket 服务器（处理配对和重连认证）
@MainActor
class RemoteHostServer: ObservableObject {
    static let shared = RemoteHostServer()
    
    @Published var isRunning = false
    @Published var connectedDevices: [String] = []
    
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ClientConnection] = [:]
    private var currentPairingCode: String?
    private var pairingCodeExpiry: Date?
    private var pendingPairingName: String?
    private var eventSeq = 0
    private weak var appState: AppState?
    private var cancellables: Set<AnyCancellable> = []
    
    private let port: UInt16 = 8765
    
    private init() {}

    func bind(appState: AppState) {
        self.appState = appState
        cancellables.removeAll()

        appState.$aiInstances
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.broadcastAISnapshot()
            }
            .store(in: &cancellables)

        appState.$groupChats
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.broadcastGroupChatsSnapshot()
            }
            .store(in: &cancellables)

        SessionManager.shared.$sessionStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.broadcastAISnapshot()
            }
            .store(in: &cancellables)
    }
    
    struct ClientConnection {
        let connection: NWConnection
        var isAuthenticated: Bool
        var publicKey: String?
        var pendingChallenge: Data?
        var deviceName: String?
        var pendingPairingCode: String?  // 延迟消费：验证成功后才消费
    }
    
    // MARK: - Lifecycle
    
    /// 清理可能占用端口的旧进程
    private func cleanupPort() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-ti", ":\(port)"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty {
                // 获取 PID 列表
                let pids = output.components(separatedBy: .newlines)
                    .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
                
                // Get current process PID to avoid killing ourselves
                let currentPID = ProcessInfo.processInfo.processIdentifier
                
                for pid in pids where pid != currentPID {
                    print("[RemoteHost] Cleaning up process PID: \(pid) occupying port \(port)")
                    kill(pid, SIGKILL)
                }
                
                // Wait for processes to exit
                if !pids.filter({ $0 != currentPID }).isEmpty {
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        } catch {
            print("[RemoteHost] Port cleanup failed: \(error)")
        }
    }
    
    func start() throws {
        // Avoid binding the same port multiple times. Pairing UI may call start() repeatedly.
        if listener != nil { return }
        
        // Clean up any processes that might be occupying the port
        cleanupPort()
        
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        
        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.isRunning = (state == .ready)
            }
        }
        
        listener?.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in
                self?.handleNewConnection(conn)
            }
        }
        
        listener?.start(queue: .global(qos: .userInitiated))
        print("[RemoteHost] Starting on port \(port)")
    }
    
    func stop() {
        for (_, client) in connections {
            client.connection.cancel()
        }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
    }
    
    // MARK: - Pairing Code
    
    func generatePairingCode() -> String {
        let code = String(format: "%06d", Int.random(in: 0..<1000000))
        currentPairingCode = code
        pairingCodeExpiry = Date().addingTimeInterval(60)
        return code
    }
    
    private func validateAndConsumePairingCode(_ code: String) -> Bool {
        guard let current = currentPairingCode,
              let expiry = pairingCodeExpiry,
              code == current, Date() < expiry else {
            return false
        }
        currentPairingCode = nil
        pairingCodeExpiry = nil
        return true
    }
    
    /// 仅验证配对码，不消费（用于 pairRequest 阶段）
    private func validatePairingCode(_ code: String) -> Bool {
        guard let current = currentPairingCode,
              let expiry = pairingCodeExpiry,
              code == current, Date() < expiry else {
            return false
        }
        return true
    }
    
    /// 消费配对码（在 challengeResponse 验证成功后调用）
    private func consumePairingCode(_ code: String) {
        if currentPairingCode == code {
            currentPairingCode = nil
            pairingCodeExpiry = nil
        }
    }
    
    // MARK: - QR Payload
    
    func generateQRPayload(wssEndpoint: String) -> PairingQRPayload {
        let code = generatePairingCode()
        let deviceName = Host.current().localizedName ?? "Mac"
        let localWs = Self.localWebSocketEndpoint(port: port)
        
        return PairingQRPayload(
            deviceId: DeviceIdentity.shared.deviceId,
            deviceName: deviceName,
            publicKeyFingerprint: DeviceIdentity.shared.publicKeyFingerprint,
            endpointWss: wssEndpoint,
            endpointWsLocal: localWs,
            pairingCode: code,
            expiresAt: Date().addingTimeInterval(60)
        )
    }

    private static func localWebSocketEndpoint(port: UInt16) -> String? {
        guard let ip = localIPv4Address() else { return nil }
        return "ws://\(ip):\(port)"
    }

    private static func localIPv4Address() -> String? {
        var addresses: [(name: String, address: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = ptr.pointee.ifa_flags
            if (flags & UInt32(IFF_UP)) == 0 { continue }
            if (flags & UInt32(IFF_LOOPBACK)) != 0 { continue }
            guard let addr = ptr.pointee.ifa_addr else { continue }
            if addr.pointee.sa_family != UInt8(AF_INET) { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result != 0 { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            let ip = String(cString: hostname)
            // Skip link-local 169.254.x.x
            if ip.hasPrefix("169.254.") { continue }
            addresses.append((name: name, address: ip))
        }

        // Prefer Wi‑Fi / primary interface names first.
        let preferred = ["en0", "en1"]
        for iface in preferred {
            if let match = addresses.first(where: { $0.name == iface }) {
                return match.address
            }
        }
        return addresses.first?.address
    }
    
    // MARK: - Challenge Generation
    
    private func generateChallenge() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
    
    // MARK: - Connection Handling
    
    private func handleNewConnection(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        connections[id] = ClientConnection(
            connection: conn,
            isAuthenticated: false,
            publicKey: nil,
            pendingChallenge: nil,
            deviceName: nil
        )
        
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .cancelled = state {
                    self?.connections.removeValue(forKey: id)
                    self?.updateConnectedDevices()
                }
            }
        }
        
        conn.start(queue: .global(qos: .userInitiated))
        receiveMessage(from: conn, id: id)
    }
    
    private func receiveMessage(from conn: NWConnection, id: ObjectIdentifier) {
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let data = data else {
                if let error {
                    print("[RemoteHost] receiveMessage error: \(error)")
                    conn.cancel()
                } else {
                    self?.receiveMessage(from: conn, id: id)
                }
                return
            }
            Task { @MainActor in
                self?.handleMessage(data, from: id)
                self?.receiveMessage(from: conn, id: id)
            }
        }
    }
    
    private func handleMessage(_ data: Data, from id: ObjectIdentifier) {
        guard var client = connections[id],
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }
        
        let shouldUpdateDevicesAfterHandling = (type == "authResponse" || type == "challengeResponse")
        
        switch type {
        // 已配对设备重连认证
        case "authHello":
            handleAuthHello(data, client: &client, id: id)
            
        case "authResponse":
            handleAuthResponse(data, client: &client, id: id)
            
        // 首次配对
        case "pairRequest":
            handlePairRequest(data, client: &client, id: id)
            
        case "challengeResponse":
            handleChallengeResponse(data, client: &client, id: id)
            
        // 业务消息（需已认证）
        case "sendMessage":
            if client.isAuthenticated { handleSendMessage(data) }
            
        case "terminalChoice":
            if client.isAuthenticated { handleTerminalChoice(data) }
            
        case "syncRequest":
            if client.isAuthenticated { handleSyncRequest(data, to: client.connection) }

        case "createGroupChat":
            if client.isAuthenticated { handleCreateGroupChat(data, to: client.connection) }

        case "sendGroupMessage":
            if client.isAuthenticated { handleSendGroupMessage(data, to: client.connection) }
            
        default:
            break
        }
        
        connections[id] = client
        if shouldUpdateDevicesAfterHandling {
            updateConnectedDevices()
        }
    }
    
    // MARK: - Re-authentication Flow
    
    private func handleAuthHello(_ data: Data, client: inout ClientConnection, id: ObjectIdentifier) {
        guard let hello = try? JSONDecoder().decode(AuthHello.self, from: data) else { return }
        
        if AuthorizedDeviceStore.shared.isAuthorized(publicKey: hello.phonePublicKey) {
            // 已授权，发 challenge
            let challenge = generateChallenge()
            client.publicKey = hello.phonePublicKey
            client.pendingChallenge = challenge
            client.deviceName = hello.phoneName
            
            let response = AuthChallenge(challenge: challenge.base64EncodedString())
            sendJSON(response, to: client.connection)
        } else {
            // 未授权
            let denied = AuthDenied(error: "not authorized, please pair")
            sendJSON(denied, to: client.connection)
        }
    }
    
    private func handleAuthResponse(_ data: Data, client: inout ClientConnection, id: ObjectIdentifier) {
        guard let response = try? JSONDecoder().decode(AuthResponse.self, from: data),
              let challenge = client.pendingChallenge,
              let signature = Data(base64Encoded: response.signature) else {
            return
        }
        
        if DeviceIdentity.verify(signature: signature, for: challenge, publicKeyBase64: response.phonePublicKey) {
            client.isAuthenticated = true
            client.pendingChallenge = nil
            
            sendJSON(AuthOK(), to: client.connection)
            sendAISnapshot(to: client.connection)
            sendGroupChatsSnapshot(to: client.connection)
            print("[RemoteHost] Device re-authenticated: \(client.deviceName ?? "Unknown")")
        } else {
            let denied = AuthDenied(error: "signature verification failed")
            sendJSON(denied, to: client.connection)
            client.connection.cancel()
        }
    }
    
    // MARK: - First-time Pairing Flow
    
    private func handlePairRequest(_ data: Data, client: inout ClientConnection, id: ObjectIdentifier) {
        guard let request = try? JSONDecoder().decode(PairRequest.self, from: data) else {
            let response = PairResponse(success: false, challenge: nil, error: "Failed to parse pairing request")
            sendJSON(response, to: client.connection)
            return
        }
        
        // Validate only, don't consume the code yet (wait until challengeResponse succeeds)
        guard validatePairingCode(request.pairingCode) else {
            let response = PairResponse(success: false, challenge: nil, error: "Invalid or expired pairing code")
            sendJSON(response, to: client.connection)
            return
        }
        
        let challenge = generateChallenge()
        client.pendingChallenge = challenge
        client.publicKey = request.phonePublicKey
        client.deviceName = request.phoneName
        client.pendingPairingCode = request.pairingCode  // Store pairing code for later consumption
        pendingPairingName = request.phoneName
        
        let response = PairResponse(success: true, challenge: challenge.base64EncodedString(), error: nil)
        sendJSON(response, to: client.connection)
    }
    
    private func handleChallengeResponse(_ data: Data, client: inout ClientConnection, id: ObjectIdentifier) {
        guard let response = try? JSONDecoder().decode(ChallengeResponse.self, from: data),
              let challenge = client.pendingChallenge,
              let publicKey = client.publicKey,
              let signature = Data(base64Encoded: response.signature) else {
            let denied = AuthDenied(error: "invalid challenge response")
            sendJSON(denied, to: client.connection)
            return
        }
        
        if DeviceIdentity.verify(signature: signature, for: challenge, publicKeyBase64: publicKey) {
            client.isAuthenticated = true
            client.pendingChallenge = nil
            
            // Consume pairing code after successful verification (fixes retry issue)
            if let code = client.pendingPairingCode {
                consumePairingCode(code)
                client.pendingPairingCode = nil
            }
            
            // Store authorization (using actual name)
            let name = pendingPairingName ?? client.deviceName ?? "iPhone"
            AuthorizedDeviceStore.shared.authorize(publicKey: publicKey, name: name)
            pendingPairingName = nil
            
            let complete = PairComplete(
                macDeviceId: DeviceIdentity.shared.deviceId,
                macDeviceName: Host.current().localizedName ?? "Mac"
            )
            sendJSON(complete, to: client.connection)
            sendAISnapshot(to: client.connection)
            sendGroupChatsSnapshot(to: client.connection)
            print("[RemoteHost] Device paired: \(name)")
        } else {
            let denied = AuthDenied(error: "Authentication failed")
            sendJSON(denied, to: client.connection)
            client.connection.cancel()
        }
    }
    
    // MARK: - Business Messages
    
    private func handleSendMessage(_ data: Data) {
        guard let payload = try? JSONDecoder().decode(SendMessagePayload.self, from: data) else { return }
        
        guard let appState, let ai = appState.aiInstance(for: payload.aiId) else {
            let msg = MessageDTO(
                id: UUID(),
                senderId: payload.aiId,
                senderType: "system",
                senderName: "System",
                content: "AI instance not found (id: \(payload.aiId.uuidString))",
                timestamp: Date()
            )
            let response = AIResponsePayload(aiId: payload.aiId, message: msg, isStreaming: false)
            broadcast(type: "aiResponse", payload: response)
            return
        }

        let text = payload.text
        print("[RemoteHost] Received message for AI \(payload.aiId): \(text)")

        Task.detached(priority: .userInitiated) { [ai, text] in
            do {
                try await SessionManager.shared.startSession(for: ai)
                try await SessionManager.shared.sendMessage(text, to: ai)
                _ = try await SessionManager.shared.waitForResponse(from: ai)
            } catch {
                await MainActor.run {
                    let msg = MessageDTO(
                        id: UUID(),
                        senderId: ai.id,
                        senderType: "system",
                        senderName: "System",
                        content: "Send failed: \(error.localizedDescription)",
                        timestamp: Date()
                    )
                    let response = AIResponsePayload(aiId: ai.id, message: msg, isStreaming: false)
                    RemoteHostServer.shared.broadcast(type: "aiResponse", payload: response)
                }
            }
        }
    }
    
    private func handleTerminalChoice(_ data: Data) {
        guard let payload = try? JSONDecoder().decode(TerminalChoicePayload.self, from: data) else { return }
        
        // TODO: 转发给 SessionManager
        print("[RemoteHost] Terminal choice for AI \(payload.aiId): \(payload.choice)")
    }
    
    private func handleSyncRequest(_ data: Data, to conn: NWConnection) {
        // iOS 端重连后需要快照：AI 状态 + 群聊。
        sendAISnapshot(to: conn)
        sendGroupChatsSnapshot(to: conn)
    }

    // MARK: - AI Status

    private func broadcastAISnapshot() {
        guard !connections.values.filter({ $0.isAuthenticated }).isEmpty else { return }
        guard let appState else { return }
        for ai in appState.aiInstances {
            broadcastAIStatus(for: ai)
        }
    }

    private func sendAISnapshot(to conn: NWConnection) {
        guard let appState else { return }
        for ai in appState.aiInstances {
            sendAIStatus(for: ai, to: conn)
        }
    }

    // MARK: - Group Chats

    private func broadcastGroupChatsSnapshot() {
        guard connections.values.contains(where: { $0.isAuthenticated }) else { return }
        guard let appState else { return }

        let chats = appState.groupChats.map { chat in
            GroupChatDTO(
                id: chat.id,
                name: chat.name,
                memberIds: chat.memberIds,
                mode: chat.mode.rawValue,
                isActive: chat.isActive,
                messages: chat.messages.map { message in
                    MessageDTO(
                        id: message.id,
                        senderId: message.senderId,
                        senderType: message.senderType.rawValue,
                        senderName: message.senderName,
                        content: message.content,
                        timestamp: message.timestamp
                    )
                }
            )
        }

        let payload = GroupChatsSnapshotPayload(chats: chats)
        broadcast(type: "groupChatsSnapshot", payload: payload)
    }

    private func sendGroupChatsSnapshot(to conn: NWConnection) {
        guard let appState else { return }

        let chats = appState.groupChats.map { chat in
            GroupChatDTO(
                id: chat.id,
                name: chat.name,
                memberIds: chat.memberIds,
                mode: chat.mode.rawValue,
                isActive: chat.isActive,
                messages: chat.messages.map { message in
                    MessageDTO(
                        id: message.id,
                        senderId: message.senderId,
                        senderType: message.senderType.rawValue,
                        senderName: message.senderName,
                        content: message.content,
                        timestamp: message.timestamp
                    )
                }
            )
        }

        let payload = GroupChatsSnapshotPayload(chats: chats)
        sendEvent(type: "groupChatsSnapshot", payload: payload, to: conn)
    }

    private func handleCreateGroupChat(_ data: Data, to conn: NWConnection) {
        guard let payload = try? JSONDecoder().decode(CreateGroupChatPayload.self, from: data) else {
            sendEvent(type: "groupChatError", payload: GroupChatErrorPayload(error: "Failed to parse group chat request"), to: conn)
            return
        }
        guard let appState else {
            sendEvent(type: "groupChatError", payload: GroupChatErrorPayload(error: "AppState not initialized"), to: conn)
            return
        }

        appState.createGroupChat(name: payload.name, memberIds: payload.memberIds)
        sendGroupChatsSnapshot(to: conn)
    }

    private func handleSendGroupMessage(_ data: Data, to conn: NWConnection) {
        guard let payload = try? JSONDecoder().decode(SendGroupMessagePayload.self, from: data) else {
            sendEvent(type: "groupChatError", payload: GroupChatErrorPayload(error: "Failed to parse group message"), to: conn)
            return
        }
        guard let appState else {
            sendEvent(type: "groupChatError", payload: GroupChatErrorPayload(error: "AppState not initialized"), to: conn)
            return
        }

        appState.sendUserMessage(payload.text, to: payload.chatId)
        // Group chat updates are auto-broadcast by appState.$groupChats sink.
    }

    private func broadcastAIStatus(for ai: AIInstance) {
        let status = SessionManager.shared.sessionStatus[ai.id]
        let payload = AIStatusPayload(
            aiId: ai.id,
            name: ai.name,
            provider: ai.type.rawValue,
            isRunning: status == .running,
            workingDirectory: ai.workingDirectory
        )
        broadcast(type: "aiStatus", payload: payload)
    }

    private func sendAIStatus(for ai: AIInstance, to conn: NWConnection) {
        let status = SessionManager.shared.sessionStatus[ai.id]
        let payload = AIStatusPayload(
            aiId: ai.id,
            name: ai.name,
            provider: ai.type.rawValue,
            isRunning: status == .running,
            workingDirectory: ai.workingDirectory
        )
        sendEvent(type: "aiStatus", payload: payload, to: conn)
    }
    
    // MARK: - Broadcasting
    
    func broadcast<T: Encodable>(type: String, payload: T) {
        eventSeq += 1
        guard let payloadData = try? JSONEncoder().encode(payload),
              let payloadJSON = String(data: payloadData, encoding: .utf8) else { return }
        
        let event = RemoteEvent(type: type, seq: eventSeq, payloadJSON: payloadJSON)
        guard let data = try? JSONEncoder().encode(event) else { return }
        
        for (_, client) in connections where client.isAuthenticated {
            sendData(data, to: client.connection)
        }
    }

    private func sendEvent<T: Encodable>(type: String, payload: T, to conn: NWConnection) {
        eventSeq += 1
        guard let payloadData = try? JSONEncoder().encode(payload),
              let payloadJSON = String(data: payloadData, encoding: .utf8) else { return }

        let event = RemoteEvent(type: type, seq: eventSeq, payloadJSON: payloadJSON)
        guard let data = try? JSONEncoder().encode(event) else { return }
        sendData(data, to: conn)
    }
    
    // MARK: - Helpers
    
    private func updateConnectedDevices() {
        connectedDevices = connections.values
            .filter { $0.isAuthenticated }
            .compactMap { $0.deviceName ?? $0.publicKey }
    }
    
    private func sendJSON<T: Encodable>(_ value: T, to conn: NWConnection) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        sendData(data, to: conn)
    }
    
    private func sendData(_ data: Data, to conn: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "msg", metadata: [metadata])
        conn.send(content: data, contentContext: context, completion: .idempotent)
    }
}
