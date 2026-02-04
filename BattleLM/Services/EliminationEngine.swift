// BattleLM/Services/EliminationEngine.swift
import Foundation
import Combine

/// 淘汰引擎 - 基于评价计算应该淘汰的 AI
class EliminationEngine: ObservableObject {
    
    static let shared = EliminationEngine()
    
    /// 淘汰阈值 (淘汰评分最低的比例)
    @Published var eliminationThreshold: Double = 0.3
    
    /// 最低淘汰分数 (低于此分数会被淘汰)
    @Published var minimumScore: Int = 4
    
    private init() {}
    
    // MARK: - Elimination Calculation
    
    /// 计算应该淘汰的 AI
    func calculateEliminations(
        aiInstances: [AIInstance],
        evaluations: [UUID: [AIEvaluation]]
    ) -> [UUID] {
        
        // 计算每个 AI 的平均分
        var avgScores: [UUID: Double] = [:]
        
        for ai in aiInstances {
            if let evals = evaluations[ai.id], !evals.isEmpty {
                let scores = evals.map { Double($0.score) }
                let avg = scores.reduce(0, +) / Double(scores.count)
                avgScores[ai.id] = avg
            } else {
                // 没有评价的 AI 给予中等分数
                avgScores[ai.id] = 5.0
            }
        }
        
        // 打印分数
        for (id, score) in avgScores {
            if let ai = aiInstances.first(where: { $0.id == id }) {
                print("📊 \(ai.name): \(String(format: "%.1f", score))/10")
            }
        }
        
        // 按分数排序（从低到高）
        let sorted = avgScores.sorted { $0.value < $1.value }
        
        var toEliminate: [UUID] = []
        
        // 方法 1: 淘汰低于最低分数的
        for (aiId, score) in sorted {
            if score < Double(minimumScore) {
                toEliminate.append(aiId)
            }
        }
        
        // 方法 2: 如果没有低于最低分的，淘汰比例最低的
        if toEliminate.isEmpty && aiInstances.count > 2 {
            let eliminateCount = max(1, Int(Double(aiInstances.count) * eliminationThreshold))
            toEliminate = sorted.prefix(eliminateCount).map { $0.key }
        }
        
        // 确保至少留下一个 AI
        if toEliminate.count >= aiInstances.count {
            toEliminate = Array(toEliminate.dropLast())
        }
        
        return toEliminate
    }
    
    // MARK: - Score Analysis
    
    /// 获取 AI 的评价统计
    func getScoreStatistics(
        for aiId: UUID,
        evaluations: [AIEvaluation]
    ) -> ScoreStatistics {
        
        guard !evaluations.isEmpty else {
            return ScoreStatistics(
                average: 0,
                min: 0,
                max: 0,
                count: 0
            )
        }
        
        let scores = evaluations.map { $0.score }
        let avg = Double(scores.reduce(0, +)) / Double(scores.count)
        
        return ScoreStatistics(
            average: avg,
            min: scores.min() ?? 0,
            max: scores.max() ?? 0,
            count: scores.count
        )
    }
}

// MARK: - Supporting Types

struct ScoreStatistics {
    let average: Double
    let min: Int
    let max: Int
    let count: Int
}

