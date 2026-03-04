// BattleLM/Views/Chat/ChatTextField.swift
import SwiftUI
import AppKit

/// macOS 上更可靠的输入框：强制每次输入同步到 Binding
/// 用于绕开 SwiftUI TextField 在某些视图切换/Sheet 关闭后偶发的绑定不同步问题。
struct ChatTextField: NSViewRepresentable {
    typealias NSViewType = NSTextField

    let placeholder: String
    @Binding var text: String
    var focusId: UUID? = nil
    var focusRequestId: Binding<UUID?> = .constant(nil)
    var onCommit: (() -> Void)? = nil
    var onFocusChange: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        // NSTextField 的默认 cell 会按基线绘制，且在无边框/透明背景时看起来“偏上”；
        // 用自定义 cell 让文本在固定高度内垂直居中，避免 1:1 输入栏视觉错位。
        field.cell = VerticallyCenteredTextFieldCell(textCell: "")
        field.stringValue = text
        field.placeholderString = placeholder
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.isEditable = context.environment.isEnabled
        field.isSelectable = true
        field.isEnabled = context.environment.isEnabled
        field.usesSingleLineMode = false
        field.lineBreakMode = .byWordWrapping
        field.font = .systemFont(ofSize: 15)
        field.maximumNumberOfLines = 5
        
        // 允许纵向自适应
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        
        context.coordinator.ensureAttached(to: field)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // SwiftUI 可能复用 NSView 但重建 Coordinator；这里每次都确保 delegate/observer 绑定正确
        context.coordinator.ensureAttached(to: nsView)
        context.coordinator.isInUpdateNSView = true
        defer { context.coordinator.isInUpdateNSView = false }

        let shouldBeEnabled = context.environment.isEnabled
        if nsView.isEnabled != shouldBeEnabled || nsView.isEditable != shouldBeEnabled {
            context.coordinator.isProgrammaticUpdate = true
            defer { context.coordinator.isProgrammaticUpdate = false }
            nsView.isEnabled = shouldBeEnabled
            nsView.isEditable = shouldBeEnabled
        }

        let previousSwiftUIText = context.coordinator.lastSeenSwiftUIText
        context.coordinator.lastSeenSwiftUIText = text

        let currentFieldText = context.coordinator.currentText(in: nsView)
        if currentFieldText != text {
            // 输入中尽量避免回写以免打断输入法；但“清空”是用户明确动作（已发送），需要立即同步到编辑器。
            if text.isEmpty && !previousSwiftUIText.isEmpty {
                context.coordinator.isProgrammaticUpdate = true
                defer { context.coordinator.isProgrammaticUpdate = false }
                if let editor = nsView.currentEditor() as? NSTextView {
                    editor.string = ""
                }
                nsView.stringValue = ""
            } else if !context.coordinator.isEditing, nsView.currentEditor() == nil {
                context.coordinator.isProgrammaticUpdate = true
                defer { context.coordinator.isProgrammaticUpdate = false }
                nsView.stringValue = text
            }
        }
        nsView.placeholderString = placeholder

        // Sheet 关闭 / 视图重建后，有时 responder chain 不会自动把焦点给到输入框；
        // 这里用“请求式聚焦”确保新建实例后可立即输入。
        if let focusId,
           context.environment.isEnabled,
           focusRequestId.wrappedValue == focusId,
           nsView.window != nil,
           !context.coordinator.didAttemptFocusForCurrentRequest {
            context.coordinator.didAttemptFocusForCurrentRequest = true
            DispatchQueue.main.async { [weak nsView] in
                guard let nsView, let window = nsView.window else { return }
                if window.firstResponder !== nsView.currentEditor() {
                    window.makeFirstResponder(nsView)
                }
            }
        } else if focusRequestId.wrappedValue != focusId {
            context.coordinator.didAttemptFocusForCurrentRequest = false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, focusId: focusId, focusRequestId: focusRequestId, onCommit: onCommit, onFocusChange: onFocusChange)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>
        private let focusId: UUID?
        private var focusRequestId: Binding<UUID?>
        private let onCommit: (() -> Void)?
        private let onFocusChange: ((Bool) -> Void)?
        private(set) var isEditing: Bool = false
        var isProgrammaticUpdate: Bool = false
        var isInUpdateNSView: Bool = false
        var didAttemptFocusForCurrentRequest: Bool = false
        var lastSeenSwiftUIText: String

        init(text: Binding<String>, focusId: UUID?, focusRequestId: Binding<UUID?>, onCommit: (() -> Void)?, onFocusChange: ((Bool) -> Void)?) {
            self.text = text
            self.focusId = focusId
            self.focusRequestId = focusRequestId
            self.onCommit = onCommit
            self.onFocusChange = onFocusChange
            self.lastSeenSwiftUIText = text.wrappedValue
        }

        deinit {
            if let obs = firstResponderObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        func currentText(in field: NSTextField) -> String {
            if let editor = field.currentEditor() as? NSTextView {
                return editor.string
            }
            return field.stringValue
        }

        private func setBoundText(_ newText: String, synchronous: Bool) {
            if synchronous || !isInUpdateNSView {
                text.wrappedValue = newText
                return
            }

            DispatchQueue.main.async { [weak self] in
                self?.text.wrappedValue = newText
            }
        }

        private var firstResponderObserver: NSObjectProtocol?
        private weak var observedField: NSTextField?

        func ensureAttached(to field: NSTextField) {
            if field.delegate !== self {
                field.delegate = self
            }

            // Return 键提交（以及部分情况下的 endEditing action）
            if field.target !== self {
                field.target = self
            }
            if field.action != #selector(Coordinator.commitAction(_:)) {
                field.action = #selector(Coordinator.commitAction(_:))
            }

            // 监听 firstResponder 变化以检测焦点（click 进入时触发）
            if observedField !== field {
                observedField = field
                if let obs = firstResponderObserver {
                    NotificationCenter.default.removeObserver(obs)
                }
                // 延迟检查 firstResponder，因为窗口可能还没准备好
                firstResponderObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didUpdateNotification,
                    object: nil,
                    queue: .main
                ) { [weak self, weak field] _ in
                    guard let self, let field, let window = field.window else { return }
                    let isFocused = window.firstResponder === field.currentEditor()
                    if isFocused != self.lastReportedFocus {
                        self.lastReportedFocus = isFocused
                        self.onFocusChange?(isFocused)
                    }
                }
            }
        }

        private var lastReportedFocus: Bool = false

        func controlTextDidBeginEditing(_ obj: Notification) {
            isEditing = true
            // Focus already handled by firstResponder observer
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            guard !isProgrammaticUpdate else { return }
            setBoundText(currentText(in: field), synchronous: false)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            guard !isProgrammaticUpdate else {
                isEditing = false
                return
            }
            setBoundText(currentText(in: field), synchronous: false)
            isEditing = false
            // Focus already handled by firstResponder observer
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // 输入法候选态下的 Enter 用于确认，不应触发发送。
                if textView.hasMarkedText() {
                    return false
                }
                // Shift+Enter → 插入换行
                if NSEvent.modifierFlags.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    // 同步绑定文本
                    let field = control as? NSTextField
                    let value = field.map(currentText(in:)) ?? text.wrappedValue
                    setBoundText(value, synchronous: false)
                    return true
                }
                // 普通 Enter → 发送
                let field = control as? NSTextField
                let value = field.map(currentText(in:)) ?? text.wrappedValue
                setBoundText(value, synchronous: true)
                onCommit?()
                return true
            }
            return false
        }

        @objc func commitAction(_ sender: NSTextField) {
            if let editor = sender.currentEditor() as? NSTextView, editor.hasMarkedText() {
                return
            }
            setBoundText(currentText(in: sender), synchronous: true)
            onCommit?()
        }
    }
}

/// 让 NSTextField 在固定高度中垂直居中绘制/编辑文本。
private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var result = super.drawingRect(forBounds: rect)
        let textSize = cellSize(forBounds: rect)
        let delta = result.height - textSize.height
        if delta > 0 {
            result.origin.y += delta / 2
            result.size.height -= delta
        }
        return result
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        drawingRect(forBounds: rect)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}
