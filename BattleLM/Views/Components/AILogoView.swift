// BattleLM/Views/Components/AILogoView.swift
import SwiftUI

/// AI Logo 视图 - 使用官方 Logo 图片
struct AILogoView: View {
    let aiType: AIType
    var size: CGFloat = 20
    
    var body: some View {
        // Asset Catalog 配置了 light/dark 变体，系统会自动选择正确的图片
        Image(aiType.logoImageName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

/// 带背景圆圈的 AI Logo
struct AILogoCircle: View {
    let aiType: AIType
    var size: CGFloat = 32
    var showBackground: Bool = true
    
    var body: some View {
        ZStack {
            if showBackground {
                Circle()
                    .fill(Color(hex: aiType.color).opacity(0.15))
                    .frame(width: size, height: size)
            }
            
            Image(aiType.logoImageName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size * 0.6, height: size * 0.6)
        }
    }
}

#Preview {
    HStack(spacing: 20) {
        ForEach(AIType.allCases) { type in
            VStack {
                AILogoView(aiType: type, size: 32)
                AILogoCircle(aiType: type, size: 48)
                Text(type.displayName)
                    .font(.caption)
            }
        }
    }
    .padding()
}
