// BattleLM/Views/History/HistoryListView.swift
// Session Manager — cc-switch 风格的左右分栏布局。
// 左: session 列表（按日期分组）  右: 选中 session 的完整对话

import SwiftUI

struct HistoryListView: View {
    @State private var allEntries: [CLIHistoryEntry] = []
    @State private var groups: [CLIHistoryGroup] = []
    @State private var selectedEntry: CLIHistoryEntry?
    @State private var isLoading = true
    @State private var filterType: AIType? = nil  // nil = show all
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 12) {
                Text("Session Manager")
                    .font(.title3)
                    .fontWeight(.bold)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Main content: left-right split
            HSplitView {
                // LEFT: Session list
                sessionListPanel
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)

                // RIGHT: Conversation detail
                detailPanel
                    .frame(minWidth: 400, idealWidth: 550)
            }
        }
        .frame(minWidth: 750, minHeight: 500)
        .background(Color(.windowBackgroundColor))
        .task {
            loadHistory()
        }
    }

    // MARK: - Left Panel: Session List

    private var sessionListPanel: some View {
        VStack(spacing: 0) {
            // Header with count + filter
            VStack(spacing: 6) {
                HStack {
                    Text("Sessions")
                        .font(.headline)
                    if !isLoading {
                        let totalCount = groups.reduce(0) { $0 + $1.entries.count }
                        Text("\(totalCount)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.1)))
                    }
                    Spacer()
                }

                // AI type filter buttons
                HStack(spacing: 4) {
                    FilterChip(label: "All", isActive: filterType == nil) {
                        applyFilter(nil)
                    }
                    FilterChip(label: "Claude", icon: "claude", isActive: filterType == .claude) {
                        applyFilter(.claude)
                    }
                    FilterChip(label: "Codex", icon: "codex", isActive: filterType == .codex) {
                        applyFilter(.codex)
                    }
                    FilterChip(label: "Gemini", icon: "gemini", isActive: filterType == .gemini) {
                        applyFilter(.gemini)
                    }
                    FilterChip(label: "Qwen", icon: "qwen", isActive: filterType == .qwen) {
                        applyFilter(.qwen)
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(groups) { group in
                            // Don't show group labels to match cc-switch clean look
                            ForEach(group.entries) { entry in
                                SessionRow(
                                    entry: entry,
                                    isSelected: selectedEntry?.id == entry.id
                                )
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        selectedEntry = entry
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Color(.controlBackgroundColor).opacity(0.3))
    }

    // MARK: - Right Panel: Detail

    private var detailPanel: some View {
        Group {
            if let entry = selectedEntry {
                HistoryDetailView(entry: entry)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Select a session to view")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.5))
            Text("No sessions found")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("CLI history will appear here")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadHistory() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = CLIHistoryReader.shared.readAllHistory(limit: 200)
            DispatchQueue.main.async {
                self.allEntries = entries
                self.applyFilter(self.filterType)
                self.isLoading = false
            }
        }
    }

    private func applyFilter(_ type: AIType?) {
        filterType = type
        let filtered = type == nil ? allEntries : allEntries.filter { $0.cliType == type }
        groups = CLIHistoryReader.shared.groupByDate(filtered)
        // Auto-select first visible entry
        if let first = groups.first?.entries.first {
            selectedEntry = first
        } else {
            selectedEntry = nil
        }
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let label: String
    var icon: String? = nil
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    AILogoView(aiType: AIType(rawValue: icon) ?? .claude, size: 12)
                }
                Text(label)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
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

// MARK: - Session Row (left panel)

private struct SessionRow: View {
    let entry: CLIHistoryEntry
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // CLI icon
            AILogoView(aiType: entry.cliType, size: 18)

            VStack(alignment: .leading, spacing: 3) {
                // Project name / display text
                Text(projectLabel)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                // Relative time
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                    Text(relativeTime)
                        .font(.system(size: 11))
                }
                .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected
                    ? Color.accentColor.opacity(0.2)
                    : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
    }

    /// Show project folder name (last path component)
    private var projectLabel: String {
        if entry.cliType == .claude {
            // Project path is the full JSONL path, extract the project dir name
            let pathComponents = entry.project.components(separatedBy: "/")
            // Find the projects/<encoded-name> part
            if let projectsIdx = pathComponents.firstIndex(of: "projects"),
               projectsIdx + 1 < pathComponents.count {
                let encoded = pathComponents[projectsIdx + 1]
                let decoded = encoded.split(separator: "-").map(String.init)
                return decoded.last ?? entry.displayText
            }
        }
        // Fallback: use display text
        return entry.displayText
    }

    private var relativeTime: String {
        let interval = Date().timeIntervalSince(entry.timestamp)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60)) min ago" }
        if interval < 86400 { return "\(Int(interval / 3600)) hr ago" }
        let days = Int(interval / 86400)
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days) days ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: entry.timestamp)
    }
}
