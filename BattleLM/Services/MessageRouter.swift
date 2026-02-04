// BattleLM/Services/MessageRouter.swift
import Foundation
import Combine

/// 消息路由器 - 负责在 AI 之间路由消息
class MessageRouter: ObservableObject {
    static let shared = MessageRouter()
    
    private let sessionManager = SessionManager.shared
    
    private init() {}
    
    // MARK: - Broadcast Messages
    
    /// 广播用户消息给群聊中的所有 AI（流式响应）
    /// - Parameters:
    ///   - message: 用户消息
    ///   - chat: 群聊
    ///   - aiInstances: 所有 AI 实例
    ///   - onResponse: 每个 AI 响应到达时的回调（先到先调用）
    func broadcastUserMessage(
        _ message: String,
        to chat: GroupChat,
        aiInstances: [AIInstance],
        onResponse: @escaping (AIResponse) async -> Void
    ) async {
        
        let activeAIs = aiInstances.filter { 
            chat.activeMemberIds.contains($0.id) && !$0.isEliminated 
        }
        
        // 并行发送给所有 AI，响应到达时立即回调
        await withTaskGroup(of: AIResponse?.self) { group in
            for ai in activeAIs {
                group.addTask {
                    await self.sendAndWait(message, to: ai)
                }
            }
            
            // 先到先处理
            for await response in group {
                if let response = response {
                    await onResponse(response)
                }
            }
        }
    }
    
    /// 让一个 AI 评价另一个 AI 的输出
    func requestEvaluation(
        from evaluator: AIInstance,
        of targetResponse: String,
        targetAI: AIInstance
    ) async -> AIEvaluation? {
        
        let prompt = """
        请评价以下 AI (\(targetAI.name)) 的分析结果，并给出评分。
        
        分析内容：
        "\(targetResponse)"
        
        请用以下格式回复：
        评分：[0-10分]
        优点：[优点描述]
        缺点：[缺点描述]
        """
        
        guard let response = await sendAndWait(prompt, to: evaluator) else {
            return nil
        }
        
        return parseEvaluation(response.content, targetId: targetAI.id)
    }
    
    // MARK: - Private Methods
    
    /// 发送消息并等待响应
    private func sendAndWait(_ message: String, to ai: AIInstance) async -> AIResponse? {
        do {
            // 发送消息
            try await sessionManager.sendMessage(message, to: ai)
            
            // 等待响应
            let response = try await sessionManager.waitForResponse(
                from: ai,
                stableSeconds: 3.0,
                maxWait: 60.0
            )
            
            guard !response.isEmpty else { return nil }
            
            return AIResponse(
                aiId: ai.id,
                aiName: ai.name,
                content: response,
                timestamp: Date()
            )
            
        } catch {
            print("❌ Error sending to \(ai.name): \(error)")
            return nil
        }
    }
    
    /// 发送消息并流式获取响应（用于 1:1 聊天）
    /// - Parameters:
    ///   - message: 用户消息
    ///   - ai: 目标 AI
    ///   - onUpdate: 每次内容变化时的回调 (内容, 是否思考中, 是否完成)
    func sendWithStreaming(
        _ message: String,
        to ai: AIInstance,
        onUpdate: @escaping (String, Bool, Bool) -> Void
    ) async {
        do {
            // 发送消息
            try await sessionManager.sendMessage(message, to: ai)
            
            // 流式获取响应
            try await sessionManager.streamResponse(
                from: ai,
                onUpdate: onUpdate,
                stableSeconds: 4.0,
                maxWait: 120.0
            )
        } catch {
            print("❌ Error streaming from \(ai.name): \(error)")
            await MainActor.run {
                onUpdate("Error: \(error.localizedDescription)", false, true)
            }
        }
    }
    
    /// 解析评价响应 - 使用关键词推断分数
    private func parseEvaluation(_ content: String, targetId: UUID) -> AIEvaluation {
        var pros = ""
        var cons = ""
        
        let lines = content.split(separator: "\n")
        
        for line in lines {
            let lineStr = String(line).trimmingCharacters(in: .whitespaces)
            
            if lineStr.contains("优点") || lineStr.contains("Pros") {
                pros = lineStr.replacingOccurrences(of: "优点：", with: "")
                               .replacingOccurrences(of: "优点:", with: "")
                               .trimmingCharacters(in: .whitespaces)
            } else if lineStr.contains("缺点") || lineStr.contains("Cons") {
                cons = lineStr.replacingOccurrences(of: "缺点：", with: "")
                               .replacingOccurrences(of: "缺点:", with: "")
                               .trimmingCharacters(in: .whitespaces)
            }
        }
        
        // 使用关键词推断分数
        let score = inferScoreFromKeywords(content)
        
        return AIEvaluation(
            targetId: targetId,
            score: score,
            pros: pros,
            cons: cons
        )
    }
    
    /// 通过关键词推断评价分数 (0-10)
    private func inferScoreFromKeywords(_ content: String) -> Int {
        // 高分关键词 (9-10分)
        let excellentKeywords = ["非常好", "非常棒", "很棒", "很好", "太棒了", "完美", "出色", "优秀", 
                                  "excellent", "perfect", "amazing", "outstanding", "精彩", "准确"]
        
        // 中高分关键词 (7-8分)
        let goodKeywords = ["不错", "好", "挺好", "可以", "正确", "有道理", "合理", "清晰",
                            "good", "nice", "correct", "reasonable", "clear", "有帮助"]
        
        // 中等分关键词 (5-6分)
        let okayKeywords = ["还可以", "一般", "还行", "尚可", "基本", "普通",
                            "okay", "acceptable", "average", "so-so", "中规中矩"]
        
        // 低分关键词 (3-4分)
        let poorKeywords = ["不太好", "不够", "有问题", "欠缺", "需要改进", "不足",
                            "not good", "needs improvement", "lacking", "问题"]
        
        // 差评关键词 (1-2分)
        let badKeywords = ["很差", "错误", "不对", "完全错误", "误导", "无用", "糟糕",
                           "wrong", "incorrect", "bad", "terrible", "useless", "misleading"]
        
        let lowercased = content.lowercased()
        
        // 按优先级检测（先检测极端评价）
        for keyword in badKeywords {
            if lowercased.contains(keyword.lowercased()) {
                return 2
            }
        }
        
        for keyword in excellentKeywords {
            if lowercased.contains(keyword.lowercased()) {
                return 9
            }
        }
        
        for keyword in poorKeywords {
            if lowercased.contains(keyword.lowercased()) {
                return 4
            }
        }
        
        for keyword in goodKeywords {
            if lowercased.contains(keyword.lowercased()) {
                return 8
            }
        }
        
        for keyword in okayKeywords {
            if lowercased.contains(keyword.lowercased()) {
                return 6
            }
        }
        
        // 默认中等分数
        return 5
    }
}

// MARK: - Supporting Types

/// AI 响应
struct AIResponse {
    let aiId: UUID
    let aiName: String
    let content: String
    let timestamp: Date
}

/// AI 评价
struct AIEvaluation {
    let targetId: UUID
    let score: Int        // 0-10
    let pros: String
    let cons: String
}
