// BattleLM/Views/Chat/ThinkingDotsView.swift
import SwiftUI

/// 三个跳动的点：用于表示 AI 正在思考（不属于气泡）。
struct ThinkingDotsView: View {
    var dotSize: CGFloat = 6
    var dotSpacing: CGFloat = 6
    var amplitude: CGFloat = 4
    var speed: Double = 4.0

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate * speed
            HStack(spacing: dotSpacing) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = Double(index) * 0.6
                    let raw = sin(t - phase)
                    let bounce = max(0, raw)
                    Circle()
                        .fill(Color.secondary.opacity(0.9))
                        .frame(width: dotSize, height: dotSize)
                        .offset(y: -amplitude * bounce)
                        .opacity(0.55 + 0.45 * bounce)
                }
            }
        }
        .accessibilityLabel("Thinking")
    }
}

