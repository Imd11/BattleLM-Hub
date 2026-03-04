// BattleLM/Views/Settings/TokenUsageView.swift
// Token 用量仪表盘 — 按来源分 Tab 显示 Claude 和 Codex 的 token 消耗统计

import SwiftUI

// MARK: - Usage Tab

enum UsageTab: Hashable {
    case all
    case source(TokenSource)
    
    var label: String {
        switch self {
        case .all: return "All"
        case .source(let s): return s.rawValue
        }
    }
}

// MARK: - Main View

struct TokenUsageView: View {
    let monitor: TokenUsageMonitor
    @State private var selectedTab: UsageTab = .all
    
    /// 有数据或已支持的来源
    private var availableSources: [TokenSource] {
        TokenSource.allCases
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Tab 栏 + 时间范围选择器
            HStack(spacing: 4) {
                usageFilterChip(label: "All", isActive: selectedTab == .all) {
                    selectedTab = .all
                }
                
                ForEach(availableSources, id: \.self) { source in
                    usageFilterChip(
                        label: source.rawValue,
                        aiType: source.aiType,
                        isActive: selectedTab == .source(source)
                    ) {
                        selectedTab = .source(source)
                    }
                }
                
                Spacer()
                
                // 时间范围选择器
                TimeRangePicker(selected: Binding(
                    get: { monitor.selectedTimeRange },
                    set: { monitor.selectedTimeRange = $0 }
                ))
            }
            .padding(.horizontal, 4)
            
            Divider()
            
            // 内容区
            ScrollView {
                let summary = monitor.summary
                
                Group {
                    switch selectedTab {
                    case .all:
                        allOverview(summary: summary)
                    case .source(let source):
                        sourceDetail(source: source, summary: summary)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }
    
    // MARK: - Filter Chip (matching Session Manager style)
    
    private func usageFilterChip(label: String, aiType: AIType? = nil, isActive: Bool, action: @escaping () -> Void) -> some View {
        UsageFilterChipButton(label: label, aiType: aiType, isActive: isActive, action: action)
    }
    
    // MARK: - All Overview Tab
    
    @ViewBuilder
    private func allOverview(summary: TokenUsageSummary) -> some View {
        if summary.totalTokens == 0 {
            emptyState(message: monitor.selectedTimeRange.emptyMessage)
        } else {
            // 总量
            VStack(alignment: .leading, spacing: 6) {
                Text("Total")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(summary.formattedTotal)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
            }
            .padding(.bottom, 4)
            
            // 各来源的比例条
            ForEach(availableSources, id: \.self) { source in
                let sourceUsage = summary.bySource[source]
                let tokens = sourceUsage?.totalTokens ?? 0
                let ratio = summary.totalTokens > 0 ? Double(tokens) / Double(summary.totalTokens) : 0
                let requests = sourceUsage?.requestCount ?? 0
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle()
                            .fill(Color(hex: source.color))
                            .frame(width: 9, height: 9)
                        Text(source.rawValue)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(formatTokenCount(tokens))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        if requests > 0 {
                            Text("(\(Int(ratio * 100))%)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    // 进度条
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.gray.opacity(0.15))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(hex: source.color))
                                .frame(width: max(0, geo.size.width * ratio))
                        }
                    }
                    .frame(height: 8)
                }
                .padding(.vertical, 4)
            }
            
            Divider()
                .padding(.vertical, 4)
            
            // input/output/cache 汇总
            HStack(spacing: 24) {
                miniStat(label: "Input", value: summary.totalInput, color: .blue)
                miniStat(label: "Output", value: summary.totalOutput, color: .green)
                if summary.totalCacheRead > 0 {
                    miniStat(label: "Cache Read", value: summary.totalCacheRead, color: .orange)
                }
            }
        }
    }
    
    // MARK: - Source Detail Tab
    
    @ViewBuilder
    private func sourceDetail(source: TokenSource, summary: TokenUsageSummary) -> some View {
        let sourceUsage = summary.bySource[source]
        let tokens = sourceUsage?.totalTokens ?? 0
        let requests = sourceUsage?.requestCount ?? 0
        
        // 该来源下的模型
        let models = Array((summary.bySourceModel[source] ?? [:]).values)
            .sorted(by: { $0.totalTokens > $1.totalTokens })
        
        if tokens == 0 {
            emptyState(message: "No \(source.rawValue) usage \(monitor.selectedTimeRange == .day24h ? "in last 24 hours" : monitor.selectedTimeRange == .week7d ? "in last 7 days" : monitor.selectedTimeRange == .month30d ? "in last 30 days" : "recorded")")
        } else {
            // 来源总量
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Total")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(formatTokenCount(tokens))
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                }
                
                Text("\(requests) requests")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                
                Spacer()
            }
            .padding(.bottom, 4)
            
            // 模型列表 + 进度条
            if !models.isEmpty {
                Text("Models")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                
                ForEach(Array(models.prefix(8)), id: \.id) { modelUsage in
                    let ratio = tokens > 0 ? Double(modelUsage.totalTokens) / Double(tokens) : 0
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(modelUsage.model)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Text(formatTokenCount(modelUsage.totalTokens))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        }
                        
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.gray.opacity(0.12))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(hex: source.color).opacity(0.7))
                                    .frame(width: max(0, geo.size.width * ratio))
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(.vertical, 4)
                }
            }
            
            Divider()
                .padding(.vertical, 4)
            
            // Input / Output / Cache 明细
            let sourceInput = sourceUsage?.inputTokens ?? 0
            let sourceOutput = sourceUsage?.outputTokens ?? 0
            
            HStack(spacing: 24) {
                miniStat(label: "Input", value: sourceInput, color: .blue)
                miniStat(label: "Output", value: sourceOutput, color: .green)
            }
        }
    }
    
    // MARK: - Helpers
    
    @ViewBuilder
    private func emptyState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
    
    @ViewBuilder
    private func miniStat(label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(formatTokenCount(value))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
    }
    
}

// MARK: - Usage Filter Chip (matching Session Manager's FilterChip)

private struct UsageFilterChipButton: View {
    let label: String
    var aiType: AIType? = nil
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let aiType {
                    AILogoView(aiType: aiType, size: 14)
                }
                Text(label)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.2) : (isHovered ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Time Range Picker

/// 紧凑的时间范围选择器（分段控件风格）
private struct TimeRangePicker: View {
    @Binding var selected: UsageTimeRange
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(UsageTimeRange.allCases, id: \.self) { range in
                TimeRangeButton(
                    label: range.rawValue,
                    isSelected: selected == range
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selected = range
                    }
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

/// 单个时间范围按钮
private struct TimeRangeButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Group {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.accentColor.opacity(0.7))
                        } else if isHovered {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.primary.opacity(0.06))
                        }
                    }
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
