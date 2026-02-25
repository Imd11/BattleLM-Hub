import SwiftUI
import CoreImage.CIFilterBuiltins

/// Pairing QR Code View
struct PairingQRView: View {
    @ObservedObject private var cloudflared = CloudflaredManager.shared
    @ObservedObject private var remoteHost = RemoteHostServer.shared
    
    @State private var qrPayload: PairingQRPayload?
    @State private var qrImage: NSImage?  // Cached QR code image
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var countdown = 60
    @State private var countdownTimer: Timer?
    @State private var didAutoDismiss = false
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header - Fixed at top
            HStack {
                Text("Device Pairing")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Divider()
            
            // Main content
            if !remoteHost.connectedDevices.isEmpty && qrPayload == nil && errorMessage == nil {
                ScrollView {
                    connectedStateView
                        .padding()
                }
            } else if isLoading {
                Spacer()
                loadingView
                Spacer()
            } else if let error = errorMessage {
                Spacer()
                errorView(error)
                    .padding()
                Spacer()
            } else if let payload = qrPayload {
                ScrollView {
                    qrCodeView(payload)
                        .padding()
                }
            }
            
            // Connected devices - Fixed at bottom
            if !remoteHost.connectedDevices.isEmpty {
                Divider()
                connectedDevicesSection
            }
        }
        .frame(width: 400, height: 520)
        .task {
            // If a device is already connected, show status instead of generating a QR.
            guard remoteHost.connectedDevices.isEmpty else {
                isLoading = false
                errorMessage = nil
                qrPayload = nil
                qrImage = nil
                countdownTimer?.invalidate()
                return
            }
            await startPairing()
        }
        .onChange(of: remoteHost.connectedDevices) { devices in
            guard !devices.isEmpty else { return }
            
            countdownTimer?.invalidate()
            countdownTimer = nil
            
            // Auto dismiss only for an active pairing flow.
            guard !didAutoDismiss, qrPayload != nil else {
                isLoading = false
                errorMessage = nil
                qrPayload = nil
                qrImage = nil
                return
            }
            
            didAutoDismiss = true
            dismiss()
        }
        .onDisappear {
            countdownTimer?.invalidate()
        }
    }
    
    // MARK: - Views
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            
            if !cloudflared.isInstalled {
                Text("cloudflared not detected")
                    .foregroundColor(.secondary)
                Text("brew install cloudflared")
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(6)
            } else {
                Text("Starting remote tunnel...")
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            
            Text(message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Retry") {
                Task { await startPairing() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    private func qrCodeView(_ payload: PairingQRPayload) -> some View {
        VStack(spacing: 16) {
            // QR Code (using cached image)
            if let image = qrImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .background(Color.white)
                    .cornerRadius(12)
            }
            
            Text("Scan QR code with iPhone")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            // Countdown
            HStack(spacing: 4) {
                Image(systemName: "clock")
                Text("Expires in \(countdown)s")
            }
            .foregroundColor(countdown <= 10 ? .orange : .secondary)
            
            // Refresh button
            if countdown <= 0 {
                Button("Refresh QR Code") {
                    Task { await regenerateQR() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var connectedStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
            
            Text("\(remoteHost.connectedDevices.count) device(s) connected")
                .font(.headline)
            
            Button("Add New Device") {
                didAutoDismiss = false
                Task { await startPairing() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxHeight: .infinity)
    }
    
    private var connectedDevicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connected Devices (\(remoteHost.connectedDevices.count))")
                .font(.headline)
            
            ForEach(remoteHost.connectedDevices, id: \.self) { device in
                HStack {
                    Image(systemName: "iphone")
                    Text(device)
                    Spacer()
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                }
                .padding(8)
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
    }
    
    // MARK: - Actions
    
    private func startPairing() async {
        isLoading = true
        errorMessage = nil
        
        // Check cloudflared
        guard cloudflared.isInstalled else {
            errorMessage = "Please install cloudflared first:\nbrew install cloudflared"
            isLoading = false
            return
        }
        
        do {
            // 启动 WebSocket 服务器
            try remoteHost.start()
            
            // 启动隧道
            let wssEndpoint = try await cloudflared.startTunnel(localPort: Int(8765))
            
            // 生成二维码
            let payload = remoteHost.generateQRPayload(wssEndpoint: wssEndpoint)
            qrPayload = payload
            qrImage = generateQRCode(from: payload)  // 缓存二维码图片
            isLoading = false
            
            // 启动倒计时
            startCountdown()
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
    
    private func regenerateQR() async {
        guard let currentEndpoint = cloudflared.tunnelURL else {
            await startPairing()
            return
        }
        
        let payload = remoteHost.generateQRPayload(wssEndpoint: currentEndpoint)
        qrPayload = payload
        qrImage = generateQRCode(from: payload)  // 缓存二维码图片
        countdown = 60
        startCountdown()
    }
    
    private func startCountdown() {
        countdown = 60
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if countdown > 0 {
                countdown -= 1
            } else {
                countdownTimer?.invalidate()
            }
        }
    }
    
    // MARK: - QR Generation
    
    private func generateQRCode(from payload: PairingQRPayload) -> NSImage? {
        guard let base64 = try? payload.toBase64() else { return nil }
        
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(base64.utf8)
        filter.correctionLevel = "M"
        
        guard let outputImage = filter.outputImage else { return nil }
        
        // Scale up
        let scale = 10.0
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        
        return NSImage(cgImage: cgImage, size: NSSize(width: scaledImage.extent.width, height: scaledImage.extent.height))
    }
}
