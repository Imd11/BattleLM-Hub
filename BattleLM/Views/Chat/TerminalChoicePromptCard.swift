// BattleLM/Views/Chat/TerminalChoicePromptCard.swift
import SwiftUI

struct TerminalChoicePromptCard: View {
    let aiName: String
    let prompt: TerminalChoicePrompt
    let isSubmitting: Bool
    var onOpenTerminal: (() -> Void)?
    let onSelect: (TerminalChoiceOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)

                Text("\(aiName) needs your confirmation")
                    .font(.headline)

                Spacer()

                if let onOpenTerminal {
                    Button("Open terminal") {
                        onOpenTerminal()
                    }
                    .buttonStyle(.link)
                    .disabled(isSubmitting)
                }
            }

            Text(prompt.title)
                .font(.subheadline)
                .foregroundColor(.primary)

            if let body = prompt.body, !body.isEmpty {
                Text(body)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            if let hint = prompt.hint, !hint.isEmpty {
                Text(hint)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(prompt.options) { option in
                    Button {
                        onSelect(option)
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(option.number).")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(option.label)
                                .font(.subheadline)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(.controlAccentColor))
                    .disabled(isSubmitting)
                }
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.yellow.opacity(0.25), lineWidth: 1)
        )
    }
}
