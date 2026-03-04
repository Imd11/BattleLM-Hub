// BattleLM/Views/Chat/ModelSelectorView.swift
import SwiftUI
import AppKit

/// 模型选择器 — capsule 按钮 + 级联菜单（模型 → 推理深度）
struct ModelSelectorView: View {
    let aiType: AIType
    let aiId: UUID
    @EnvironmentObject var appState: AppState
    
    @State private var isHovered = false
    
    private var currentAI: AIInstance? {
        appState.aiInstance(for: aiId)
    }
    
    private var currentDisplayName: String {
        currentAI?.modelDisplayName ?? aiType.defaultModelId
    }
    
    var body: some View {
        Button {
            showCascadingMenu()
        } label: {
            HStack(spacing: 4) {
                Text(currentDisplayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isHovered ? Color.primary.opacity(0.1) : Color.primary.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    // MARK: - NSMenu 级联菜单
    
    private func showCascadingMenu() {
        let menu = NSMenu(title: "Model")
        
        let models = aiType.availableModels
        let selectedModelId = currentAI?.effectiveModel ?? aiType.defaultModelId
        let selectedEffort = currentAI?.selectedReasoningEffort
        
        for model in models {
            if model.hasReasoningEffort {
                // 带子菜单的模型项
                let item = NSMenuItem(title: model.displayName, action: nil, keyEquivalent: "")
                
                // 如果是当前选中的模型，加粗
                if model.id == selectedModelId {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
                    ]
                    item.attributedTitle = NSAttributedString(string: model.displayName, attributes: attrs)
                }
                
                // 创建子菜单（推理深度）
                let submenu = NSMenu(title: model.displayName)
                let effortForComparison = model.id == selectedModelId ? selectedEffort : nil
                let defaultEffort = model.defaultEffort ?? .medium
                
                for effort in model.reasoningEfforts {
                    let effortItem = NSMenuItem(
                        title: effort.displayName,
                        action: #selector(ModelMenuDelegate.selectModelEffort(_:)),
                        keyEquivalent: ""
                    )
                    
                    // 当前选中标记
                    let isCurrentEffort = model.id == selectedModelId
                        && (effortForComparison ?? defaultEffort) == effort
                    if isCurrentEffort {
                        effortItem.state = .on
                    }
                    
                    // 用 representedObject 传递选择信息
                    effortItem.representedObject = ModelEffortSelection(
                        modelId: model.id,
                        effort: effort,
                        isDefault: model.isDefault,
                        isDefaultEffort: effort == model.defaultEffort
                    )
                    
                    submenu.addItem(effortItem)
                }
                
                item.submenu = submenu
                menu.addItem(item)
            } else {
                // 无子菜单的模型项，直接选中
                let item = NSMenuItem(
                    title: model.displayName,
                    action: #selector(ModelMenuDelegate.selectModel(_:)),
                    keyEquivalent: ""
                )
                
                if model.id == selectedModelId {
                    item.state = .on
                }
                
                item.representedObject = ModelEffortSelection(
                    modelId: model.id,
                    effort: nil,
                    isDefault: model.isDefault,
                    isDefaultEffort: true
                )
                
                menu.addItem(item)
            }
        }
        
        // 设置 delegate 来处理 action
        let delegate = ModelMenuDelegate(appState: appState, aiId: aiId)
        // 用 objc_setAssociatedObject 防止 delegate 被释放
        objc_setAssociatedObject(menu, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        
        for item in menu.items {
            item.target = delegate
            if let submenu = item.submenu {
                for subItem in submenu.items {
                    subItem.target = delegate
                }
            }
        }
        
        // 在按钮位置弹出菜单
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
        }
    }
}

// MARK: - Selection Data

struct ModelEffortSelection {
    let modelId: String
    let effort: ReasoningEffort?
    let isDefault: Bool
    let isDefaultEffort: Bool
}

// MARK: - Menu Delegate

class ModelMenuDelegate: NSObject {
    let appState: AppState
    let aiId: UUID
    
    init(appState: AppState, aiId: UUID) {
        self.appState = appState
        self.aiId = aiId
    }
    
    @objc func selectModel(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ModelEffortSelection else { return }
        appState.setSelectedModel(selection.isDefault ? nil : selection.modelId, for: aiId)
        appState.setSelectedReasoningEffort(nil, for: aiId)
    }
    
    @objc func selectModelEffort(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ModelEffortSelection else { return }
        appState.setSelectedModel(selection.isDefault ? nil : selection.modelId, for: aiId)
        appState.setSelectedReasoningEffort(
            selection.isDefaultEffort ? nil : selection.effort,
            for: aiId
        )
    }
}
