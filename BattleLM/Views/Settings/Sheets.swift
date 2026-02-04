// BattleLM/Views/Settings/Sheets.swift
import SwiftUI
import UniformTypeIdentifiers

/// 添加 AI 对话框
struct AddAISheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    
    @State private var selectedType: AIType = .claude
    @State private var customName: String = "Claude"  // 默认填充第一个类型的名称
    @State private var workingDirectory: String = ""
    @State private var showFolderPicker: Bool = false
    @State private var isCardContainerHovered: Bool = false
    @State private var scrollOffset: CGFloat = 0
    @State private var showDuplicateAlert: Bool = false
    @State private var showInstallHelp: Bool = false

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
                                ForEach(Array(AIType.allCases.enumerated()), id: \.element.id) { index, type in
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
                            let cardCount = AIType.allCases.count
                            let targetIndex = Int(newValue * CGFloat(cardCount - 1))
                            let clampedIndex = max(0, min(cardCount - 1, targetIndex))
                            if let targetType = AIType.allCases[safe: clampedIndex] {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(targetType.id, anchor: .leading)
                                }
                            }
                        }
                    }
                    
                    // 自定义滚动条轨道（始终预留空间）
                    GeometryReader { outerGeo in
                        let totalWidth = outerGeo.size.width
                        let cardCount = CGFloat(AIType.allCases.count)
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
                        showFolderPicker = true
                    }
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
                                try await SessionManager.shared.startSession(for: ai)
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
            }
        }
        .padding(24)
        .frame(width: 500, height: 450)
        .alert("Name Already Exists", isPresented: $showDuplicateAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("An AI instance with the name \"\(customName.isEmpty ? selectedType.displayName : customName)\" already exists. Please choose a different name.")
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                workingDirectory = url.path
            }
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
    
    @State private var chatName: String = ""
    @State private var selectedAIIds: Set<UUID> = []
    
    var body: some View {
        VStack(spacing: 20) {
            // 标题
            Text("Create Group Chat")
                .font(.title2)
                .fontWeight(.bold)
            
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
                    Text("No AI instances available. Please add some first.")
                        .foregroundColor(.secondary)
                        .italic()
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
                    .frame(maxHeight: 200)  // 固定最大高度，超出则滚动
                }
            }
            
            Spacer()
            
            // 按钮
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Create") {
                    let name = chatName.isEmpty ? "New Chat" : chatName
                    appState.createGroupChat(
                        name: name,
                        memberIds: Array(selectedAIIds)
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selectedAIIds.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400, height: 450)  // 稍微增加高度
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
    case terminal = "Terminal"
    case display = "Display"
    case shortcuts = "Shortcuts"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .appearance: return "paintbrush"
        case .terminal: return "terminal"
        case .display: return "rectangle.3.group"
        case .shortcuts: return "keyboard"
        }
    }
}

struct SettingsSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @State private var selectedTab: SettingsTab = .appearance
    
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
            .frame(width: 160)
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
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                
                Divider()
                
                // 内容区
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch selectedTab {
                        case .appearance:
                            appearanceContent
                        case .terminal:
                            terminalContent
                        case .display:
                            displayContent
                        case .shortcuts:
                            shortcutsContent
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: 650, height: 500)
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
    
    // MARK: - Terminal Tab
    private var terminalContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Terminal Theme")
                .font(.headline)
            
            Text(themeGroupLabel)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 10) {
                ForEach(availableThemes) { theme in
                    ThemePreviewCard(
                        theme: theme,
                        isSelected: appState.terminalTheme.id == theme.id
                    ) {
                        appState.terminalTheme = theme
                    }
                }
            }
        }
    }
    
    // MARK: - Display Tab
    private var displayContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle("Show Terminal Panel", isOn: $appState.showTerminalPanel)
            
            HStack {
                Text("Terminal Position")
                Spacer()
                Picker("", selection: $appState.terminalPosition) {
                    ForEach(TerminalPosition.allCases) { position in
                        Label(position.displayName, systemImage: position.iconName)
                            .tag(position)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            
            HStack {
                Text("Font Size")
                Spacer()
                Picker("", selection: $appState.fontSize) {
                    ForEach(FontSizeOption.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
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
    private var availableThemes: [TerminalTheme] {
        TerminalTheme.themes(for: appState.appAppearance, colorScheme: colorScheme)
    }
    
    private var themeGroupLabel: String {
        switch appState.appAppearance {
        case .dark:
            return "Dark Themes"
        case .light:
            return "Light Themes"
        case .system:
            return colorScheme == .dark ? "Dark Themes (System)" : "Light Themes (System)"
        }
    }
    
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
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .foregroundColor(isSelected ? .accentColor : .primary)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
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
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
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

/// 主题预览卡片
struct ThemePreviewCard: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 0) {
                // 预览区域
                VStack(alignment: .leading, spacing: 2) {
                    Text("$ codex")
                        .foregroundColor(theme.promptColor.color)
                    Text("✦ Hello")
                        .foregroundColor(theme.responseColor.color)
                    Text("// ok")
                        .foregroundColor(theme.commentColor.color)
                }
                .font(.system(.caption2, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(theme.backgroundColor.color)
                
                // 名称
                Text(theme.name)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(Color(.controlBackgroundColor))
            }
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
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
