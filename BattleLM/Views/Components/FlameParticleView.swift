// BattleLM/Views/Components/FlameParticleView.swift
import SwiftUI
import SpriteKit

/// 高质量动态火焰粒子效果 - 环绕头像的火焰光环
struct FlameParticleView: View {
    let intensity: Int  // 1-5 强度等级
    let avatarSize: CGFloat
    
    var body: some View {
        SpriteView(
            scene: FlameScene(intensity: intensity, size: CGSize(width: avatarSize + 40, height: avatarSize + 40)),
            options: [.allowsTransparency]
        )
        .frame(width: avatarSize + 40, height: avatarSize + 40)
        .allowsHitTesting(false)
    }
}

/// 火焰粒子场景
class FlameScene: SKScene {
    private let intensity: Int
    private var emitters: [SKEmitterNode] = []
    
    init(intensity: Int, size: CGSize) {
        self.intensity = max(0, min(5, intensity))
        super.init(size: size)
        self.backgroundColor = .clear
        self.scaleMode = .aspectFit
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func didMove(to view: SKView) {
        view.allowsTransparency = true
        setupFlameEmitters()
    }
    
    private func setupFlameEmitters() {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - 20
        
        // 根据强度创建不同层数的火焰
        if intensity >= 1 {
            addFlameLayer(center: center, radius: radius, layer: .core)
        }
        if intensity >= 2 {
            addFlameLayer(center: center, radius: radius, layer: .main)
        }
        if intensity >= 3 {
            addFlameLayer(center: center, radius: radius, layer: .tip)
        }
        if intensity >= 4 {
            addFlameLayer(center: center, radius: radius, layer: .spark)
        }
    }
    
    private enum FlameLayer {
        case core   // 底层核心 - 暗红色
        case main   // 主火焰层 - 橙色
        case tip    // 尖端层 - 黄白色
        case spark  // 火星层
    }
    
    private func addFlameLayer(center: CGPoint, radius: CGFloat, layer: FlameLayer) {
        // 环绕圆周放置多个发射点
        let emitterCount: Int
        let angleOffset: CGFloat
        
        switch layer {
        case .core:
            emitterCount = 12 + intensity * 2
            angleOffset = 0
        case .main:
            emitterCount = 8 + intensity * 2
            angleOffset = .pi / 24
        case .tip:
            emitterCount = 6 + intensity
            angleOffset = .pi / 12
        case .spark:
            emitterCount = 4 + intensity
            angleOffset = .pi / 6
        }
        
        for i in 0..<emitterCount {
            let angle = (CGFloat(i) / CGFloat(emitterCount)) * .pi * 2 + angleOffset
            let x = center.x + cos(angle) * radius
            let y = center.y + sin(angle) * radius
            
            let emitter = createEmitter(for: layer, at: CGPoint(x: x, y: y), angle: angle)
            
            // 底部火焰更强（物理真实）
            let bottomFactor = 1.0 + 0.5 * sin(angle - .pi / 2)
            emitter.particleBirthRate *= bottomFactor
            
            addChild(emitter)
            emitters.append(emitter)
        }
    }
    
    private func createEmitter(for layer: FlameLayer, at position: CGPoint, angle: CGFloat) -> SKEmitterNode {
        let emitter = SKEmitterNode()
        emitter.position = position
        
        // 火焰粒子纹理（使用内置圆形）
        emitter.particleTexture = createFlameTexture()
        
        // 发射方向：向外 + 向上
        let outwardAngle = angle + .pi / 2  // 垂直于圆周
        let upwardBias: CGFloat = .pi / 6   // 向上偏移
        emitter.emissionAngle = outwardAngle + upwardBias
        emitter.emissionAngleRange = .pi / 4
        
        // 根据层级设置不同参数
        switch layer {
        case .core:
            emitter.particleBirthRate = CGFloat(15 + intensity * 5)
            emitter.particleLifetime = 0.6 + CGFloat(intensity) * 0.1
            emitter.particleLifetimeRange = 0.2
            emitter.particleSpeed = 30 + CGFloat(intensity) * 10
            emitter.particleSpeedRange = 15
            emitter.particleScale = 0.15 + CGFloat(intensity) * 0.03
            emitter.particleScaleRange = 0.05
            emitter.particleScaleSpeed = -0.1
            emitter.particleAlpha = 0.8
            emitter.particleAlphaSpeed = -0.8
            emitter.particleColorBlendFactor = 1.0
            emitter.particleColor = NSColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1.0)  // 暗红
            emitter.particleBlendMode = .add
            
        case .main:
            emitter.particleBirthRate = CGFloat(20 + intensity * 8)
            emitter.particleLifetime = 0.5 + CGFloat(intensity) * 0.1
            emitter.particleLifetimeRange = 0.15
            emitter.particleSpeed = 50 + CGFloat(intensity) * 15
            emitter.particleSpeedRange = 20
            emitter.particleScale = 0.12 + CGFloat(intensity) * 0.025
            emitter.particleScaleRange = 0.04
            emitter.particleScaleSpeed = -0.15
            emitter.particleAlpha = 0.9
            emitter.particleAlphaSpeed = -1.0
            emitter.particleColorBlendFactor = 1.0
            emitter.particleColor = NSColor(red: 1.0, green: 0.5, blue: 0.1, alpha: 1.0)  // 橙色
            emitter.particleBlendMode = .add
            
            // 颜色序列：橙 → 黄
            emitter.particleColorSequence = createColorSequence(
                colors: [
                    NSColor(red: 1.0, green: 0.4, blue: 0.1, alpha: 1.0),
                    NSColor(red: 1.0, green: 0.7, blue: 0.2, alpha: 1.0),
                    NSColor(red: 1.0, green: 0.9, blue: 0.5, alpha: 0.0)
                ]
            )
            
        case .tip:
            emitter.particleBirthRate = CGFloat(10 + intensity * 5)
            emitter.particleLifetime = 0.3 + CGFloat(intensity) * 0.05
            emitter.particleLifetimeRange = 0.1
            emitter.particleSpeed = 70 + CGFloat(intensity) * 20
            emitter.particleSpeedRange = 30
            emitter.particleScale = 0.08 + CGFloat(intensity) * 0.02
            emitter.particleScaleRange = 0.03
            emitter.particleScaleSpeed = -0.2
            emitter.particleAlpha = 1.0
            emitter.particleAlphaSpeed = -1.5
            emitter.particleColorBlendFactor = 1.0
            emitter.particleColor = NSColor(red: 1.0, green: 0.95, blue: 0.7, alpha: 1.0)  // 黄白
            emitter.particleBlendMode = .add
            
        case .spark:
            emitter.particleBirthRate = CGFloat(2 + intensity)
            emitter.particleLifetime = 0.8 + CGFloat(intensity) * 0.2
            emitter.particleLifetimeRange = 0.3
            emitter.particleSpeed = 100 + CGFloat(intensity) * 30
            emitter.particleSpeedRange = 50
            emitter.particleScale = 0.03
            emitter.particleScaleRange = 0.01
            emitter.particleScaleSpeed = 0
            emitter.particleAlpha = 1.0
            emitter.particleAlphaSpeed = -0.8
            emitter.particleColorBlendFactor = 1.0
            emitter.particleColor = NSColor(red: 1.0, green: 0.9, blue: 0.6, alpha: 1.0)  // 亮黄
            emitter.particleBlendMode = .add
            emitter.yAcceleration = 20  // 火星向上飘
        }
        
        // 通用设置
        emitter.particleRotation = 0
        emitter.particleRotationRange = .pi * 2
        emitter.particleRotationSpeed = 1.0
        emitter.targetNode = self
        
        return emitter
    }
    
    private func createFlameTexture() -> SKTexture {
        let size = CGSize(width: 32, height: 32)
        let image = NSImage(size: size, flipped: false) { rect in
            let context = NSGraphicsContext.current?.cgContext
            
            // 创建径向渐变圆形（软边）
            let colors = [
                NSColor.white.cgColor,
                NSColor.white.withAlphaComponent(0.8).cgColor,
                NSColor.white.withAlphaComponent(0.3).cgColor,
                NSColor.clear.cgColor
            ]
            let locations: [CGFloat] = [0, 0.3, 0.7, 1.0]
            
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors as CFArray,
                                         locations: locations) {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                context?.drawRadialGradient(gradient,
                                           startCenter: center, startRadius: 0,
                                           endCenter: center, endRadius: rect.width / 2,
                                           options: [])
            }
            return true
        }
        return SKTexture(image: image)
    }
    
    private func createColorSequence(colors: [NSColor]) -> SKKeyframeSequence {
        let times = colors.enumerated().map { CGFloat($0.offset) / CGFloat(colors.count - 1) }
        return SKKeyframeSequence(keyframeValues: colors, times: times as [NSNumber])
    }
}

// MARK: - 火焰头像组合视图

/// 带火焰效果的头像视图
struct FlameAvatarView: View {
    let intensity: Int  // 0-5，0 表示无火焰
    let aiType: AIType
    let size: CGFloat
    
    var body: some View {
        ZStack {
            // 火焰粒子层（在头像下方）
            if intensity > 0 {
                FlameParticleView(intensity: intensity, avatarSize: size)
            }
            
            // 头像层
            AILogoView(aiType: aiType, size: size)
                .clipShape(Circle())
        }
        .frame(width: size + 40, height: size + 40)
    }
}

// MARK: - Preview

#Preview {
    HStack(spacing: 30) {
        ForEach(1..<6) { level in
            VStack {
                FlameParticleView(intensity: level, avatarSize: 50)
                    .frame(width: 90, height: 90)
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(10)
                Text("Level \(level)")
                    .font(.caption)
            }
        }
    }
    .padding()
    .background(Color.black)
}
