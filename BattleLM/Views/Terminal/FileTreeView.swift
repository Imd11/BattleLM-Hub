// BattleLM/Views/Terminal/FileTreeView.swift
import SwiftUI

/// 文件系统节点模型
struct FileNode: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    var children: [FileNode]?
    
    /// 文件类型图标
    var icon: String {
        if isDirectory {
            return "folder.fill"
        }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "py": return "doc.text"
        case "js", "ts", "tsx", "jsx": return "doc.text"
        case "json": return "curlybraces"
        case "md", "txt": return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        case "xcodeproj", "xcworkspace": return "hammer"
        case "gitignore": return "eye.slash"
        default: return "doc"
        }
    }
    
    /// 图标颜色
    var iconColor: Color {
        if isDirectory { return .blue }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .orange
        case "py": return .green
        case "js", "jsx": return .yellow
        case "ts", "tsx": return .blue
        case "json": return .purple
        case "md": return .cyan
        default: return .secondary
        }
    }
}

/// 文件树视图 — 显示 AI 工作目录的文件结构
struct FileTreeView: View {
    let workingDirectory: String
    @State private var rootNodes: [FileNode] = []
    @State private var expandedDirectories: Set<String> = []
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView("Loading files...")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            } else if let error = errorMessage {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rootNodes) { node in
                            FileNodeRow(
                                node: node,
                                depth: 0,
                                expandedDirectories: $expandedDirectories
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Color(.textBackgroundColor).opacity(0.3))
        .onAppear {
            loadFileTree()
        }
        .onChange(of: workingDirectory) { _ in
            loadFileTree()
        }
    }
    
    private func loadFileTree() {
        isLoading = true
        errorMessage = nil
        
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let dirPath = workingDirectory.isEmpty ? NSHomeDirectory() : workingDirectory
            
            guard fm.fileExists(atPath: dirPath) else {
                DispatchQueue.main.async {
                    errorMessage = "Directory not found:\n\(dirPath)"
                    isLoading = false
                }
                return
            }
            
            let nodes = scanDirectory(path: dirPath, depth: 0, maxDepth: 1)
            
            DispatchQueue.main.async {
                rootNodes = nodes
                isLoading = false
            }
        }
    }
    
    /// 扫描目录（懒加载，初始只展开1层）
    private func scanDirectory(path: String, depth: Int, maxDepth: Int) -> [FileNode] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        
        // 需要隐藏的文件/目录
        let hidden: Set<String> = [".git", ".DS_Store", ".build", "DerivedData", "xcuserdata", "__pycache__", "node_modules", ".swiftpm"]
        
        var nodes: [FileNode] = []
        
        for name in contents.sorted() {
            // 跳过隐藏文件
            if hidden.contains(name) { continue }
            if name.hasPrefix(".") && name != ".gitignore" { continue }
            
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &isDir)
            
            if isDir.boolValue {
                let children: [FileNode]? = depth < maxDepth
                    ? scanDirectory(path: fullPath, depth: depth + 1, maxDepth: maxDepth)
                    : []  // 占位，表示有子节点但还没加载
                nodes.append(FileNode(name: name, path: fullPath, isDirectory: true, children: children))
            } else {
                nodes.append(FileNode(name: name, path: fullPath, isDirectory: false, children: nil))
            }
        }
        
        // 文件夹排前面
        nodes.sort { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        
        return nodes
    }
}

/// 单个文件/目录行
struct FileNodeRow: View {
    let node: FileNode
    let depth: Int
    @Binding var expandedDirectories: Set<String>
    @State private var children: [FileNode]?
    @State private var isHovered: Bool = false
    
    private var isExpanded: Bool {
        expandedDirectories.contains(node.path)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 当前行
            HStack(spacing: 4) {
                // 缩进
                if depth > 0 {
                    Spacer()
                        .frame(width: CGFloat(depth) * 16)
                }
                
                // 展开/折叠箭头（仅目录）
                if node.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                } else {
                    Spacer()
                        .frame(width: 12)
                }
                
                // 图标
                Image(systemName: node.icon)
                    .font(.system(size: 12))
                    .foregroundColor(node.iconColor)
                    .frame(width: 16)
                
                // 文件名
                Text(node.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            .onTapGesture {
                if node.isDirectory {
                    toggleDirectory()
                } else {
                    openFile()
                }
            }
            
            // 子节点
            if node.isDirectory && isExpanded {
                let visibleChildren = children ?? node.children ?? []
                ForEach(visibleChildren) { child in
                    FileNodeRow(
                        node: child,
                        depth: depth + 1,
                        expandedDirectories: $expandedDirectories
                    )
                }
            }
        }
    }
    
    private func toggleDirectory() {
        if isExpanded {
            expandedDirectories.remove(node.path)
        } else {
            expandedDirectories.insert(node.path)
            // 懒加载子目录
            if children == nil {
                loadChildren()
            }
        }
    }
    
    private func loadChildren() {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(atPath: node.path) else { return }
            
            let hidden: Set<String> = [".git", ".DS_Store", ".build", "DerivedData", "xcuserdata", "__pycache__", "node_modules", ".swiftpm"]
            
            var nodes: [FileNode] = []
            for name in contents.sorted() {
                if hidden.contains(name) { continue }
                if name.hasPrefix(".") && name != ".gitignore" { continue }
                
                let fullPath = (node.path as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: fullPath, isDirectory: &isDir)
                
                if isDir.boolValue {
                    nodes.append(FileNode(name: name, path: fullPath, isDirectory: true, children: []))
                } else {
                    nodes.append(FileNode(name: name, path: fullPath, isDirectory: false, children: nil))
                }
            }
            
            nodes.sort { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            
            DispatchQueue.main.async {
                children = nodes
            }
        }
    }
    
    private func openFile() {
        NSWorkspace.shared.open(URL(fileURLWithPath: node.path))
    }
}
