// BattleLM/Services/DiscussionManager.swift
import Foundation
import Combine

/// Discussion Phase
enum DiscussionPhase: String, CaseIterable {
    case idle = "idle"
    case round1_analyzing = "analyzing"      // Round 1: Initial analysis
    case round2_evaluating = "evaluating"    // Round 2: Overall evaluation
    case round3_revising = "revising"        // Round 3: Final revision
    case complete = "complete"
    
    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .round1_analyzing: return "AI analyzing..."
        case .round2_evaluating: return "AIs exchanging opinions..."
        case .round3_revising: return "AI synthesizing revisions..."
        case .complete: return "Discussion complete"
        }
    }
    
    var systemMessage: String {
        switch self {
        case .idle: return ""
        case .round1_analyzing: return "💬 Sending to all AIs..."
        case .round2_evaluating: return "🔄 AIs exchanging opinions..."
        case .round3_revising: return "✨ AIs synthesizing feedback..."
        case .complete: return "✅ Discussion complete"
        }
    }
    
    var roundNumber: Int {
        switch self {
        case .idle: return 0
        case .round1_analyzing: return 1
        case .round2_evaluating: return 2
        case .round3_revising: return 3
        case .complete: return 3
        }
    }
}

/// Discussion Manager - Manages multi-round discussion flow
class DiscussionManager: ObservableObject {
    static let shared = DiscussionManager()
    
    @Published var phase: DiscussionPhase = .idle
    @Published var isProcessing: Bool = false
    
    // Response collection per round
    var round1Responses: [UUID: String] = [:]  // AI ID → Initial analysis
    var round2Responses: [UUID: String] = [:]  // AI ID → Overall evaluation
    var round3Responses: [UUID: String] = [:]  // AI ID → Final analysis
    
    // AI peer scores: [Evaluated AI ID: [Evaluator AI ID: Score]]
    var peerScores: [UUID: [UUID: Int]] = [:]
    
    // Expected AI list
    private var expectedAIs: Set<UUID> = []
    
    // Callbacks
    var onPhaseChange: ((DiscussionPhase) -> Void)?
    var onRoundComplete: ((Int, [UUID: String]) -> Void)?
    
    private let sessionManager = SessionManager.shared
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Start discussion
    func startDiscussion(
        question: String,
        activeAIs: [AIInstance],
        onRoundStart: @escaping (Int) async -> Void,
        onAIResponse: @escaping (AIInstance, String, Int) async -> Void
    ) async {
        await MainActor.run {
            reset()
            expectedAIs = Set(activeAIs.map { $0.id })
            phase = .round1_analyzing
            isProcessing = true
        }
        
        // Round 1: 发送用户问题给所有 AI
        await onRoundStart(1)
        await executeRound1(question: question, ais: activeAIs, onResponse: onAIResponse)
        
        // Round 2: 发送其他 AI 的分析给每个 AI
        await onRoundStart(2)
        await executeRound2(ais: activeAIs, onResponse: onAIResponse)
        
        // Round 3: 发送其他 AI 的评价给每个 AI
        await onRoundStart(3)
        await executeRound3(ais: activeAIs, onResponse: onAIResponse)
        
        await MainActor.run {
            phase = .complete
            isProcessing = false
        }
    }
    
    /// Reset state
    func reset() {
        phase = .idle
        isProcessing = false
        round1Responses.removeAll()
        round2Responses.removeAll()
        round3Responses.removeAll()
        peerScores.removeAll()
        expectedAIs.removeAll()
    }
    
    // MARK: - Private Methods
    
    /// Round 1: Initial analysis
    private func executeRound1(
        question: String,
        ais: [AIInstance],
        onResponse: @escaping (AIInstance, String, Int) async -> Void
    ) async {
        await MainActor.run {
            phase = .round1_analyzing
        }
        
        // Send to all AIs in parallel, display as each completes
        await withTaskGroup(of: (UUID, String, AIInstance)?.self) { group in
            for ai in ais where ai.isActive && !ai.isEliminated {
                group.addTask {
                    do {
                        try await self.sessionManager.sendMessage(question, to: ai)
                        let response = try await self.sessionManager.waitForResponse(
                            from: ai,
                            stableSeconds: 3.0,
                            maxWait: 60.0
                        )
                        return (ai.id, response, ai)
                    } catch {
                        print("❌ Round 1 error for \(ai.name): \(error)")
                        return nil
                    }
                }
            }
            
            // Process and display as each completes
            for await result in group {
                if let (aiId, response, ai) = result {
                    // Store response immediately
                    round1Responses[aiId] = response
                    // Display to UI immediately
                    await onResponse(ai, response, 1)
                }
            }
        }
        
        print("📊 Round 1 collected \(round1Responses.count) responses")
        onRoundComplete?(1, round1Responses)
    }
    
    /// Round 2: Overall evaluation
    private func executeRound2(
        ais: [AIInstance],
        onResponse: @escaping (AIInstance, String, Int) async -> Void
    ) async {
        await MainActor.run {
            phase = .round2_evaluating
        }
        
        // Build all prompts first (round1Responses is complete at this point)
        var prompts: [(AIInstance, String)] = []
        for ai in ais where ai.isActive && !ai.isEliminated {
            let prompt = buildRound2Prompt(for: ai, ais: ais)
            prompts.append((ai, prompt))
            print("📝 Round 2 prompt for \(ai.name):\n\(prompt.prefix(200))...")
        }
        
        // Use local variable to collect responses
        var collectedResponses: [(UUID, String, AIInstance)] = []
        
        // Send to all AIs in parallel, display as each completes
        await withTaskGroup(of: (UUID, String, AIInstance)?.self) { group in
            for (ai, prompt) in prompts {
                group.addTask {
                    do {
                        try await self.sessionManager.sendMessage(prompt, to: ai)
                        let response = try await self.sessionManager.waitForResponse(
                            from: ai,
                            stableSeconds: 3.0,
                            maxWait: 60.0
                        )
                        return (ai.id, response, ai)
                    } catch {
                        print("❌ Round 2 error for \(ai.name): \(error)")
                        return nil
                    }
                }
            }
            
            // Process and display as each completes
            for await result in group {
                if let (aiId, response, ai) = result {
                    collectedResponses.append((aiId, response, ai))
                    // Store response immediately
                    round2Responses[aiId] = response
                    // Display to UI immediately
                    await onResponse(ai, response, 2)
                    
                    // Extract scores
                    let targetAIs = ais.filter { $0.id != aiId && $0.isActive && !$0.isEliminated }
                    extractScoresFromResponse(response, evaluatorId: aiId, targetAIs: targetAIs)
                }
            }
        }
        
        print("📊 Round 2 collected \(round2Responses.count) responses")
        print("📊 Peer scores: \(peerScores.count) AIs have scores")
        onRoundComplete?(2, round2Responses)
    }
    
    /// Round 3: Final revision
    private func executeRound3(
        ais: [AIInstance],
        onResponse: @escaping (AIInstance, String, Int) async -> Void
    ) async {
        await MainActor.run {
            phase = .round3_revising
        }
        
        // Build all prompts first (round2Responses is complete at this point)
        var prompts: [(AIInstance, String)] = []
        for ai in ais where ai.isActive && !ai.isEliminated {
            let prompt = buildRound3Prompt(for: ai, ais: ais)
            prompts.append((ai, prompt))
            print("📝 Round 3 prompt for \(ai.name):\n\(prompt.prefix(200))...")
        }
        
        // Use local variable to collect responses
        var collectedResponses: [(UUID, String, AIInstance)] = []
        
        // Send to all AIs in parallel, display as each completes
        await withTaskGroup(of: (UUID, String, AIInstance)?.self) { group in
            for (ai, prompt) in prompts {
                group.addTask {
                    do {
                        try await self.sessionManager.sendMessage(prompt, to: ai)
                        let response = try await self.sessionManager.waitForResponse(
                            from: ai,
                            stableSeconds: 3.0,
                            maxWait: 60.0
                        )
                        return (ai.id, response, ai)
                    } catch {
                        print("❌ Round 3 error for \(ai.name): \(error)")
                        return nil
                    }
                }
            }
            
            // Process and display as each completes
            for await result in group {
                if let (aiId, response, ai) = result {
                    collectedResponses.append((aiId, response, ai))
                    // Store response immediately
                    round3Responses[aiId] = response
                    // Display to UI immediately
                    await onResponse(ai, response, 3)
                }
            }
        }
        
        print("📊 Round 3 collected \(round3Responses.count) responses")
        onRoundComplete?(3, round3Responses)
    }
    
    // MARK: - Prompt Builders
    
    /// Build Round 2 prompt - Evaluate other AIs and score them
    private func buildRound2Prompt(for targetAI: AIInstance, ais: [AIInstance]) -> String {
        var sections: [String] = []
        var aiNames: [String] = []
        
        for ai in ais where ai.id != targetAI.id {
            if let response = round1Responses[ai.id], !response.isEmpty {
                sections.append("\(ai.name): \(response)")
                aiNames.append(ai.name)
            }
        }
        
        let otherAnalyses = sections.joined(separator: "\n\n")
        let scoreFormat = aiNames.map { "\($0): [Evaluation] Score X/10" }.joined(separator: "\n")
        
        return """
        Other AI analyses:
        
        \(otherAnalyses)
        
        Please evaluate and score (1-10):
        \(scoreFormat)
        """
    }
    
    /// Build Round 3 prompt - Other AIs' evaluations
    private func buildRound3Prompt(for targetAI: AIInstance, ais: [AIInstance]) -> String {
        var sections: [String] = []
        
        for ai in ais where ai.id != targetAI.id {
            if let response = round2Responses[ai.id], !response.isEmpty {
                sections.append("\(ai.name) evaluation: \(response)")
            }
        }
        
        let otherEvaluations = sections.joined(separator: "\n\n")
        
        return """
        Other AIs' evaluations:
        
        \(otherEvaluations)
        
        Please provide a final analysis report synthesizing all feedback.
        """
    }
    
    // MARK: - Score Extraction
    
    /// Extract scores from Round 2 response
    /// - Parameters:
    ///   - content: AI's evaluation content
    ///   - evaluatorId: Evaluator AI's ID
    ///   - targetAIs: List of AIs being evaluated
    func extractScoresFromResponse(_ content: String, evaluatorId: UUID, targetAIs: [AIInstance]) {
        for ai in targetAIs {
            if let score = extractScore(for: ai.name, from: content) {
                // Store score
                if peerScores[ai.id] == nil {
                    peerScores[ai.id] = [:]
                }
                peerScores[ai.id]?[evaluatorId] = score
                print("📊 \(ai.name) received score: \(score)/10")
            }
        }
    }
    
    /// Extract a specific AI's score from text
    private func extractScore(for aiName: String, from content: String) -> Int? {
        // Multiple pattern matching (keeping Chinese patterns for backward compatibility)
        let patterns = [
            // Pattern 1: "Claude: ... Score 8/10" or "8/10"
            "\(aiName)[：:][\\s\\S]*?(\\d+)\\s*/\\s*10",
            // Pattern 2: "Claude: 8分" or "Claude：8分" (Chinese score format)
            "\(aiName)[：:：]\\s*(\\d+)\\s*分",
            // Pattern 3: Direct X/10 format
            "\(aiName)[\\s\\S]*?(\\d+)/10",
            // Pattern 4: "Claude 8分" (Chinese score format)
            "\(aiName)\\s+(\\d+)\\s*分",
            // Pattern 5: "评分：8" format (Chinese keyword)
            "评分[：:：]\\s*(\\d+)"
        ]
        
        for pattern in patterns {
            if let score = matchScore(pattern: pattern, in: content) {
                return min(max(score, 1), 10)  // Clamp to 1-10 range
            }
        }
        
        // 兜底：默认 5 分
        print("⚠️ Unable to extract \(aiName)'s score, using default 5")
        return 5
    }
    
    /// Regex matching to extract score
    private func matchScore(pattern: String, in content: String) -> Int? {
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let range = NSRange(content.startIndex..., in: content)
            
            if let match = regex.firstMatch(in: content, options: [], range: range) {
                if match.numberOfRanges >= 2 {
                    let scoreRange = Range(match.range(at: 1), in: content)!
                    if let score = Int(content[scoreRange]) {
                        return score
                    }
                }
            }
        } catch {
            print("❌ Regex error: \(error)")
        }
        return nil
    }
    
    /// Get average peer score for an AI
    func getAveragePeerScore(for aiId: UUID) -> Double {
        guard let scores = peerScores[aiId], !scores.isEmpty else {
            return 0.0  // Return 0 when no scores
        }
        
        let total = scores.values.reduce(0, +)
        return Double(total) / Double(scores.count)
    }
}
