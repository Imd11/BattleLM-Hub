// BattleLM/Views/Components/FlameView.swift
import SwiftUI

/// 火焰动效视图 - 根据 AI 的热度显示火焰
struct FlameView: View {
    let intensity: Int  // 0-5, 0 表示无火焰
    
    @State private var isAnimating = false
    
    // 火焰大小（根据等级）
    private var flameSize: CGFloat {
        switch intensity {
        case 0: return 0
        case 1: return 10
        case 2: return 13
        case 3: return 16
        case 4: return 19
        case 5: return 22
        default: return 0
        }
    }
    
    // 火焰颜色渐变
    private var flameGradient: LinearGradient {
        switch intensity {
        case 1:
            return LinearGradient(
                colors: [Color.orange.opacity(0.6), Color.yellow.opacity(0.4)],
                startPoint: .bottom,
                endPoint: .top
            )
        case 2:
            return LinearGradient(
                colors: [Color.orange, Color.yellow.opacity(0.6)],
                startPoint: .bottom,
                endPoint: .top
            )
        case 3:
            return LinearGradient(
                colors: [Color.orange, Color.yellow],
                startPoint: .bottom,
                endPoint: .top
            )
        case 4:
            return LinearGradient(
                colors: [Color.red.opacity(0.8), Color.orange, Color.yellow],
                startPoint: .bottom,
                endPoint: .top
            )
        case 5:
            return LinearGradient(
                colors: [Color.red, Color.orange, Color.yellow],
                startPoint: .bottom,
                endPoint: .top
            )
        default:
            return LinearGradient(colors: [.clear], startPoint: .bottom, endPoint: .top)
        }
    }
    
    // 动画速度
    private var animationDuration: Double {
        switch intensity {
        case 1...2: return 0.8
        case 3: return 0.6
        case 4...5: return 0.4
        default: return 1.0
        }
    }
    
    var body: some View {
        if intensity > 0 {
            Image(systemName: "flame.fill")
                .font(.system(size: flameSize))
                .foregroundStyle(flameGradient)
                .scaleEffect(isAnimating ? 1.1 : 0.9)
                .offset(y: isAnimating ? -1 : 1)
                .animation(
                    .easeInOut(duration: animationDuration)
                    .repeatForever(autoreverses: true),
                    value: isAnimating
                )
                .onAppear {
                    isAnimating = true
                }
        }
    }
}

// MARK: - AI 热度计算

extension AIInstance {
    /// 计算 AI 的热度等级 (0-5)
    /// 公式: F = floor((U × 0.6 + P × 0.4) / 2)
    /// U = 用户反馈得分 (0-10)
    /// P = AI 互评平均分 (1-10)
    func calculateFlameIntensity(in chat: GroupChat) -> Int {
        // 1. 计算用户反馈得分 (U)
        var likes = 0
        var dislikes = 0
        
        for message in chat.messages where message.senderId == self.id {
            if message.userReaction == .like {
                likes += 1
            } else if message.userReaction == .dislike {
                dislikes += 1
            }
        }
        
        // U_raw = likes × 2 - dislikes × 2，限制在 0-10
        let userRaw = likes * 2 - dislikes * 2
        let userScore = Double(min(max(userRaw, 0), 10))
        
        // 2. 获取 AI 互评平均分 (P)
        let peerScore = DiscussionManager.shared.getAveragePeerScore(for: self.id)
        
        // 3. 综合计算: C = U × 0.6 + P × 0.4
        let combinedScore = userScore * 0.6 + peerScore * 0.4
        
        // 4. 映射到火焰等级 (0-5): F = floor(C / 2)
        let flameLevel = Int(combinedScore / 2.0)
        
        return min(max(flameLevel, 0), 5)
    }
}

#Preview {
    HStack(spacing: 20) {
        ForEach(0..<6) { level in
            VStack {
                FlameView(intensity: level)
                    .frame(height: 30)
                Text("Level \(level)")
                    .font(.caption)
            }
        }
    }
    .padding()
}
