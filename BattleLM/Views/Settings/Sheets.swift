// BattleLM/Views/Settings/Sheets.swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 添加 AI 对话框
struct AddAISheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    
    @State private var selectedType: AIType = .claude
    @State private var customName: String = "Claude"  // 默认填充第一个类型的名称
    @State private var workingDirectory: String = ""
    @State private var isPickingFolder: Bool = false
    @State private var isCardContainerHovered: Bool = false
    @State private var scrollOffset: CGFloat = 0
    @State private var showDuplicateAlert: Bool = false
    @State private var showInstallHelp: Bool = false
    @State private var isBrowseHovered: Bool = false
    @State private var isCancelHovered: Bool = false
    @State private var isAddHovered: Bool = false

    private var selectedCLIStatus: CLIStatus? {
        appState.cliStatusCache[selectedType]
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // 标题
            Text("Add AI Instance")
                .font(.title2)
                .fontWeight(.bold)
            
            // AI 类型选择
            VStack(alignment: .leading, spacing: 12) {
                Text("Select AI Type")
                    .font(.headline)
                
                VStack(spacing: 6) {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(Array(AIType.userVisibleCases.enumerated()), id: \.element.id) { index, type in
                                    AITypeCard(
                                        type: type,
                                        isSelected: selectedType == type
                                    ) {
                                        selectedType = type
                                        customName = type.displayName  // 始终更新名称
                                        showInstallHelp = false
                                    }
                                    .id(type.id)
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                        .onChange(of: scrollOffset) { newValue in
                            // 根据滚动条位置滚动到对应的卡片
                            let cardCount = AIType.userVisibleCases.count
                            let targetIndex = Int(newValue * CGFloat(cardCount - 1))
                            let clampedIndex = max(0, min(cardCount - 1, targetIndex))
                            if let targetType = AIType.userVisibleCases[safe: clampedIndex] {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(targetType.id, anchor: .leading)
                                }
                            }
                        }
                    }
                    
                    // 自定义滚动条轨道（始终预留空间）
                    GeometryReader { outerGeo in
                        let totalWidth = outerGeo.size.width
                        let cardCount = CGFloat(AIType.userVisibleCases.count)
                        let visibleRatio = min(1.0, 4.0 / cardCount)
                        let thumbWidth = max(60, totalWidth * visibleRatio)
                        let maxOffset = totalWidth - thumbWidth
                        
                        ZStack(alignment: .leading) {
                            // 轨道背景
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 6)
                            
                            // 滑块
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.gray.opacity(0.5))
                                .frame(width: thumbWidth, height: 6)
                                .offset(x: scrollOffset * maxOffset)
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            // 计算拖动位置相对于轨道的比例
                                            let newOffset = (value.location.x - thumbWidth / 2) / maxOffset
                                            scrollOffset = max(0, min(1, newOffset))
                                        }
                                )
                        }
                        .opacity(isCardContainerHovered ? 1 : 0)
                    }
                    .frame(height: 6)
                }
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCardContainerHovered = hovering
                    }
                }
                
                // CLI 状态提示
                if let status = selectedCLIStatus {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: status.iconName)
                                .foregroundColor(statusColor(status))
                            Text("\(selectedType.displayName) CLI: \(status.displayText)")
                                .font(.caption)
                                .foregroundColor(statusColor(status))
                            
                            Spacer()

                            Button {
                                appState.refreshCLIStatus(for: selectedType)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Re-check CLI")
                            
                            if status == .notInstalled || status == .broken {
                                Button {
                                    showInstallHelp.toggle()
                                } label: {
                                    Text(showInstallHelp ? "Hide" : "How to fix")
                                        .font(.caption)
                                }
                                .buttonStyle(.link)
                            }
                        }
                        
                        // 安装指令
                        if showInstallHelp, (status == .notInstalled || status == .broken),
                           let dep = DependencyChecker.aiCLIs[selectedType] {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(status == .broken ? "Fix:" : "Installation:")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                
                                Text(dep.installHint)
                                    .font(.system(.caption, design: .monospaced))
                                    .padding(8)
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(6)
                                    .textSelection(.enabled)
                                
                                if let urlString = dep.installURL,
                                   let url = URL(string: urlString) {
                                    Link("📖 Official Documentation", destination: url)
                                        .font(.caption)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                } else {
                    // 未检测完成/暂无缓存：不阻塞 UI，只显示正在检测
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Checking \(selectedType.displayName) CLI...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // 自定义名称
            VStack(alignment: .leading, spacing: 8) {
                Text("Name (Optional)")
                    .font(.headline)
                
                TextField("e.g., Claude for Debug", text: $customName)
                    .textFieldStyle(.roundedBorder)
            }
            
            // 工作目录
            VStack(alignment: .leading, spacing: 8) {
                Text("Working Directory")
                    .font(.headline)
                
                HStack {
                    TextField("Select project folder...", text: $workingDirectory)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                    
                    Button("Browse...") {
                        pickWorkingDirectory()
                    }
                    .buttonStyle(.bordered)
                    .scaleEffect(isBrowseHovered ? 1.03 : 1.0)
                    .shadow(
                        color: isBrowseHovered ? Color.accentColor.opacity(0.20) : .clear,
                        radius: isBrowseHovered ? 8 : 0,
                        y: 2
                    )
                    .animation(.easeOut(duration: 0.12), value: isBrowseHovered)
                    .onHover { isBrowseHovered = $0 }
                }
                
                Text("The AI CLI will run in this directory")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // 按钮
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .scaleEffect(isCancelHovered ? 1.03 : 1.0)
                .shadow(
                    color: isCancelHovered ? Color.accentColor.opacity(0.18) : .clear,
                    radius: isCancelHovered ? 7 : 0,
                    y: 2
                )
                .animation(.easeOut(duration: 0.12), value: isCancelHovered)
                .onHover { isCancelHovered = $0 }
                
                Spacer()
                
                Button("Add") {
                    // 检查名称是否重复
                    let finalName = customName.isEmpty ? selectedType.displayName : customName
                    let isDuplicate = appState.aiInstances.contains { $0.name == finalName }
                    
                    if isDuplicate {
                        showDuplicateAlert = true
                        return
                    }
                    
                    let newAI = appState.addAI(
                        type: selectedType,
                        name: customName.isEmpty ? nil : customName,
                        workingDirectory: workingDirectory
                    )
                    
                    // 自动启动 AI 会话
                    if let ai = newAI {
                        Task {
                            do {
                                try await AIStreamEngineRouter.active.startSession(for: ai)
                                await MainActor.run {
                                    appState.setAIActive(true, for: ai.id)
                                }
                            } catch {
                                print("Failed to start session: \(error)")
                            }
                        }
                    }
                    
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(workingDirectory.isEmpty || selectedCLIStatus == nil || selectedCLIStatus == .notInstalled || selectedCLIStatus == .broken)
                .scaleEffect(isAddHovered ? 1.03 : 1.0)
                .shadow(
                    color: isAddHovered ? Color.accentColor.opacity(0.25) : .clear,
                    radius: isAddHovered ? 8 : 0,
                    y: 2
                )
                .animation(.easeOut(duration: 0.12), value: isAddHovered)
                .onHover { isAddHovered = $0 }
            }
        }
        .padding(24)
        .frame(width: 500, height: 450)
        .alert("Name Already Exists", isPresented: $showDuplicateAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("An AI instance with the name \"\(customName.isEmpty ? selectedType.displayName : customName)\" already exists. Please choose a different name.")
        }
        .onAppear {
            // 预热检测（幂等，不会重复执行）
            appState.startCLIDetection()
        }
    }
    
    private func statusColor(_ status: CLIStatus) -> Color {
        switch status {
        case .notInstalled: return .red
        case .broken: return .red
        case .installed: return .orange
        case .ready: return .green
        }
    }

    private func pickWorkingDirectory() {
        guard !isPickingFolder else { return }
        isPickingFolder = true

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Select project folder"

        if !workingDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: workingDirectory)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        }

        // Use app-modal presentation for reliability when this view itself is a sheet.
        panel.begin { response in
            DispatchQueue.main.async {
                isPickingFolder = false
                guard response == .OK, let url = panel.url else { return }
                workingDirectory = url.path
            }
        }
    }
}

/// AI 类型卡片
struct AITypeCard: View {
    let type: AIType
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                AILogoView(aiType: type, size: 32)
                
                Text(type.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
            }
            .frame(width: 100, height: 100)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color(.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

/// 创建群聊对话框
struct CreateGroupSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    
    enum CreateMode: String, CaseIterable {
        case quickStart = "Quick Start"
        case fromExisting = "From Existing"
    }
    
    @State private var selectedMode: CreateMode = .quickStart
    @State private var isCancelHovered: Bool = false
    @State private var isCreateHovered: Bool = false
    @State private var isBrowseHovered: Bool = false
    
    // Quick Start mode states
    @State private var selectedAITypes: Set<AIType> = []
    @State private var workingDirectory: String = NSHomeDirectory()
    
    // From Existing mode states
    @State private var selectedAIIds: Set<UUID> = []
    @State private var chatName: String = ""
    
    var body: some View {
        VStack(spacing: 20) {
            // 标题
            Text("Create Group Chat")
                .font(.title2)
                .fontWeight(.bold)
            
            // 模式选择器
            Picker("", selection: $selectedMode) {
                ForEach(CreateMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            
            // 根据模式显示不同内容
            if selectedMode == .quickStart {
                quickStartContent
            } else {
                fromExistingContent
            }
            
            Spacer()
            
            // 按钮
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .scaleEffect(isCancelHovered ? 1.03 : 1.0)
                .shadow(
                    color: isCancelHovered ? Color.accentColor.opacity(0.18) : .clear,
                    radius: isCancelHovered ? 7 : 0,
                    y: 2
                )
                .animation(.easeOut(duration: 0.12), value: isCancelHovered)
                .onHover { isCancelHovered = $0 }
                
                Spacer()
                
                Button(selectedMode == .quickStart ? "Create" : "Create") {
                    if selectedMode == .quickStart {
                        createQuickStartGroup()
                    } else {
                        createFromExistingGroup()
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selectedMode == .quickStart ? !canStartQuickStart : selectedAIIds.isEmpty)
                .scaleEffect(isCreateHovered ? 1.03 : 1.0)
                .shadow(
                    color: isCreateHovered ? Color.accentColor.opacity(0.25) : .clear,
                    radius: isCreateHovered ? 8 : 0,
                    y: 2
                )
                .animation(.easeOut(duration: 0.12), value: isCreateHovered)
                .onHover { isCreateHovered = $0 }
            }
        }
        .padding(24)
        .frame(width: 500, height: 480)
        .onAppear {
            // 预热检测 CLI（与 Add AI Sheet 一致）
            appState.startCLIDetection()
            
            // 如果已有 AI 实例，默认显示 From Existing
            if !appState.aiInstances.isEmpty {
                selectedMode = .fromExisting
            }
        }
    }
    
    // MARK: - Quick Start Content
    
    private var quickStartContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // AI 类型选择
            VStack(alignment: .leading, spacing: 10) {
                Text("Select AI Models")
                    .font(.headline)
                
                Text("Choose at least 2 AI models to battle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // AI 类型横向滚动（与 Add AI Sheet 一致）
                VStack(spacing: 8) {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(Array(AIType.userVisibleCases.enumerated()), id: \.element.id) { index, type in
                                    QuickStartAICard(
                                        type: type,
                                        isSelected: selectedAITypes.contains(type),
                                        cliStatus: appState.cliStatusCache[type]
                                    ) {
                                        if selectedAITypes.contains(type) {
                                            selectedAITypes.remove(type)
                                        } else {
                                            selectedAITypes.insert(type)
                                        }
                                    }
                                    .id(type.id)
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                    
                    // 简化的滚动指示器（只在有多于4个AI类型时显示）
                    if AIType.userVisibleCases.count > 4 {
                        HStack {
                            Spacer()
                            Text("← Scroll to see more →")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                }
            }
            
            // 工作目录
            VStack(alignment: .leading, spacing: 8) {
                Text("Working Directory")
                    .font(.headline)
                
                HStack {
                    TextField("Select project folder...", text: $workingDirectory)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                    
                    Button("Browse...") {
                        pickWorkingDirectory()
                    }
                    .buttonStyle(.bordered)
                    .scaleEffect(isBrowseHovered ? 1.03 : 1.0)
                    .shadow(
                        color: isBrowseHovered ? Color.accentColor.opacity(0.20) : .clear,
                        radius: isBrowseHovered ? 8 : 0,
                        y: 2
                    )
                    .animation(.easeOut(duration: 0.12), value: isBrowseHovered)
                    .onHover { isBrowseHovered = $0 }
                }
                
                Text("All AIs will run in this directory")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - From Existing Content
    
    private var fromExistingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 群聊名称
            VStack(alignment: .leading, spacing: 8) {
                Text("Chat Name")
                    .font(.headline)
                
                TextField("e.g., Bug Discussion", text: $chatName)
                    .textFieldStyle(.roundedBorder)
            }
            
            // 选择 AI
            VStack(alignment: .leading, spacing: 12) {
                Text("Select AI Participants")
                    .font(.headline)
                
                if appState.aiInstances.isEmpty {
                    VStack(spacing: 12) {
                        Text("No AI instances available")
                            .foregroundColor(.secondary)
                        
                        Text("Switch to \"Quick Start\" to create a group quickly")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    // 可滚动的 AI 列表
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(appState.aiInstances) { ai in
                                AISelectionRow(
                                    ai: ai,
                                    isSelected: selectedAIIds.contains(ai.id)
                                ) {
                                    if selectedAIIds.contains(ai.id) {
                                        selectedAIIds.remove(ai.id)
                                    } else {
                                        selectedAIIds.insert(ai.id)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            }
        }
    }
    
    // MARK: - Actions
    
    private func pickWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a working directory for the AI"
        
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
        }
    }
    
    private func createQuickStartGroup() {
        guard canStartQuickStart else { return }
        var createdAIs: [AIInstance] = []
        var memberIds: [UUID] = []
        
        // 批量创建 AI 实例
        for type in selectedAITypes {
            if let ai = appState.addAI(type: type, workingDirectory: workingDirectory) {
                createdAIs.append(ai)
                memberIds.append(ai.id)
            }
        }
        
        // 创建群聊
        if memberIds.count >= 2 {
            let chatName = "New Chat"
            let chatId = appState.createGroupChat(name: chatName, memberIds: memberIds)

            // Quick Start 等同于用户手动 Add AI：创建后立即启动会话。
            // addAI 会默认隐藏终端面板；Quick Start 作为“一键开打”，恢复终端面板更符合预期。
            appState.showTerminalPanel = true

            Task {
                await withTaskGroup(of: Void.self) { group in
                    for ai in createdAIs {
                        group.addTask {
                            do {
                                try await AIStreamEngineRouter.active.startSession(for: ai)
                                await MainActor.run {
                                    appState.setAIActive(true, for: ai.id)
                                }
                            } catch {
                                await MainActor.run {
                                    appState.setAIActive(false, for: ai.id)
                                    appState.appendSystemMessage("⚠️ Failed to start \(ai.name): \(error.localizedDescription)", to: chatId)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func createFromExistingGroup() {
        let name = chatName.isEmpty ? "New Chat" : chatName
        appState.createGroupChat(
            name: name,
            memberIds: Array(selectedAIIds)
        )
    }

    private var canStartQuickStart: Bool {
        guard selectedAITypes.count >= 2 else { return false }
        guard !workingDirectory.isEmpty else { return false }
        return selectedAITypes.allSatisfy { type in
            guard let status = appState.cliStatusCache[type] else { return false }
            return status == .installed || status == .ready
        }
    }
}

/// AI 类型卡片（用于 Quick Start，支持多选和 CLI 状态）
struct QuickStartAICard: View {
    let type: AIType
    let isSelected: Bool
    let cliStatus: CLIStatus?
    let action: () -> Void
    
    @State private var isHovered: Bool = false
    
    private var isReady: Bool {
        guard let status = cliStatus else { return false }
        return status == .installed || status == .ready
    }
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    AILogoView(aiType: type, size: 32)
                    
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.green)
                            .background(Circle().fill(Color(.windowBackgroundColor)).padding(-2))
                            .offset(x: 6, y: -6)
                    }
                }
                
                Text(type.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                // CLI 状态指示
                if cliStatus == nil {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(height: 10)
                } else if !isReady {
                    Text("Not installed")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                } else {
                    Text("Ready")
                        .font(.system(size: 9))
                        .foregroundColor(.green)
                }
            }
            .frame(width: 100, height: 100)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : (isHovered ? Color.primary.opacity(0.08) : Color(.controlBackgroundColor)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isReady)
        .opacity(isReady ? 1.0 : 0.6)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

/// AI 选择行
struct AISelectionRow: View {
    let ai: AIInstance
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                
                AILogoView(aiType: ai.type, size: 18)
                
                Text(ai.name)
                
                Spacer()
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : (isHovered ? Color.primary.opacity(0.08) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

#Preview("Add AI") {
    AddAISheet()
        .environmentObject(AppState())
}

#Preview("Create Group") {
    CreateGroupSheet()
        .environmentObject(AppState())
}

// MARK: - Settings Sheet

/// 设置对话框
// MARK: - Settings Tab Enum
enum SettingsTab: String, CaseIterable, Identifiable {
    case appearance = "Appearance"
    case usage = "Usage"
    case shortcuts = "Shortcuts"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .appearance: return "paintbrush"
        case .usage: return "chart.bar.fill"
        case .shortcuts: return "keyboard"
        }
    }
}

struct SettingsSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @State private var selectedTab: SettingsTab = .appearance
    @State private var isCloseHovered = false
    
    var body: some View {
        HStack(spacing: 0) {
            // 左侧 Tab 栏
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    SettingsTabButton(
                        tab: tab,
                        isSelected: selectedTab == tab
                    ) {
                        selectedTab = tab
                    }
                }
                
                Spacer()
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
            .frame(width: 190)
            .background(Color(.controlBackgroundColor))
            
            Divider()
            
            // 右侧内容区
            VStack(spacing: 0) {
                // 顶部标题栏
                HStack {
                    Text(selectedTab.rawValue)
                        .font(.title2)
                        .fontWeight(.bold)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.secondary)
                            .opacity(isCloseHovered ? 0.7 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .onHover { isCloseHovered = $0 }
                }
                .padding()
                
                Divider()
                
                // 内容区
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch selectedTab {
                        case .appearance:
                            appearanceContent
                        case .usage:
                            TokenUsageView(monitor: appState.tokenUsageMonitor)
                        case .shortcuts:
                            shortcutsContent
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: 750, height: 560)
        .onChange(of: colorScheme) { _ in
            // 当系统 colorScheme 变化时（用户选择"跟随系统"模式后，系统主题切换）
            // 需要同步更新终端主题
            if appState.appAppearance == .system {
                updateTerminalThemeIfNeeded()
            }
        }
    }
    
    // MARK: - Appearance Tab
    private var appearanceContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("App Theme")
                .font(.headline)
            
            HStack(spacing: 12) {
                ForEach(AppAppearance.allCases) { appearance in
                    AppearanceButton(
                        appearance: appearance,
                        isSelected: appState.appAppearance == appearance
                    ) {
                        appState.appAppearance = appearance
                        updateTerminalThemeIfNeeded()
                    }
                }
            }
        }
    }
    
    // MARK: - Shortcuts Tab
    private var shortcutsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts")
                .font(.headline)
            
            ShortcutRow(action: "Toggle Terminal", shortcut: "⌘ T")
            ShortcutRow(action: "New AI Instance", shortcut: "⌘ N")
            ShortcutRow(action: "Settings", shortcut: "⌘ ,")
        }
    }
    
    // MARK: - Helpers
    private func updateTerminalThemeIfNeeded() {
        // 当 App 主题切换时，强制重置终端主题为对应模式的默认主题
        let shouldUseDark: Bool
        switch appState.appAppearance {
        case .dark:
            shouldUseDark = true
        case .light:
            shouldUseDark = false
        case .system:
            shouldUseDark = colorScheme == .dark
        }
        
        // 如果当前主题的明暗模式与新 App 主题不匹配，重置为默认
        if appState.terminalTheme.isDark != shouldUseDark {
            appState.terminalTheme = shouldUseDark ? .defaultDark : .defaultLight
        }
    }
}

/// 设置 Tab 按钮
struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.iconName)
                    .frame(width: 20)
                Text(tab.rawValue)
                    .fontWeight(isSelected ? .semibold : .regular)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.15)
                    : (isHovered ? Color.primary.opacity(0.06) : Color.clear)
            )
            .foregroundColor(isSelected ? .accentColor : .primary)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// 设置分区
struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            content
        }
    }
}

/// 外观选择按钮
struct AppearanceButton: View {
    let appearance: AppAppearance
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                ZStack {
                    // 背景
                    Group {
                        switch appearance {
                        case .dark:
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.black)
                        case .light:
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white)
                        case .system:
                            HStack(spacing: 0) {
                                Color.white
                                Color.black
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .frame(width: 60, height: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    
                    Image(systemName: appearance.iconName)
                        .foregroundColor(appearance == .dark ? .white : (appearance == .light ? .black : .gray))
                }
                
                Text(appearance.displayName)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .padding(8)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.1)
                    : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
            )
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// 快捷键行
struct ShortcutRow: View {
    let action: String
    let shortcut: String
    
    var body: some View {
        HStack {
            Text(action)
                .foregroundColor(.primary)
            Spacer()
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(4)
        }
    }
}

// MARK: - Collection Safe Subscript

extension Collection {
    /// 安全访问数组元素，越界返回 nil
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

#Preview("Settings") {
    SettingsSheet()
        .environmentObject(AppState())
}
