import AletheDesign
import AletheDocuments
import AletheModel
import AppKit
import SwiftUI

/// A Markdown pane (upstream `MarkdownPane`): the file rendered, reloaded when it changes on disk,
/// with refresh, copy source, edit / save / cancel, reveal in Finder and close in its header.
/// Dragging the header reorders the pane, as with terminals.
struct MarkdownPaneView: View {
    let file: MarkdownFile
    let isFocused: Bool
    let onClose: () -> Void
    let onDrag: (CGSize?) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: metrics.size(28))
            Rectangle().fill(theme[.borderSubtle]).frame(height: 1)
            content
        }
        .background(theme[.bg])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("markdown.pane")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: metrics.space(.s)) {
            Image(systemName: "doc.richtext")
                .font(metrics.font(.caption))
                .foregroundStyle(theme[.textSecondary])
            Text(verbatim: file.name)
                .font(metrics.font(.footnote).weight(.medium))
                .foregroundStyle(theme[isFocused ? .textPrimary : .textSecondary])
                .lineLimit(1)
                .help(Text(verbatim: file.path))
            if file.hasUnsavedChanges {
                Circle().fill(theme[.statusWaiting]).frame(width: metrics.size(6), height: metrics.size(6))
                    .accessibilityLabel(Text("markdown.unsaved"))
            }
            Spacer(minLength: 0)
            if file.isEditing {
                headerButton("checkmark", label: "markdown.save", id: "markdown.save") { file.save() }
                    .keyboardShortcut("s", modifiers: .command)
                headerButton("xmark.circle", label: "markdown.cancelEdit", id: "markdown.cancelEdit") { file.cancelEditing() }
            } else {
                headerButton("arrow.clockwise", label: "markdown.refresh", id: "markdown.refresh") { file.reload() }
                headerButton(copied ? "checkmark" : "doc.on.doc", label: copied ? "markdown.copied" : "markdown.copySource",
                             id: "markdown.copy") { copySource() }
                headerButton("pencil", label: "markdown.edit", id: "markdown.edit") { file.beginEditing() }
                    .disabled(file.loadError != nil)
            }
            headerButton("folder", label: "markdown.revealInFinder", id: "markdown.reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
            headerButton("xmark", label: "markdown.close", id: "pane.close", action: onClose)
        }
        .padding(.horizontal, metrics.space(.m))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme[isFocused ? .bgElevated : .bgSunken])
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { onDrag($0.translation) }
                .onEnded { _ in onDrag(nil) }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pane.header.\(file.name)")
    }

    private func headerButton(_ symbol: String, label: LocalizedStringKey, id: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(metrics.font(.caption).weight(.semibold))
                .frame(width: metrics.size(18), height: metrics.size(18))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(theme[.textTertiary])
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(id)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if file.isEditing {
            VStack(spacing: 0) {
                if let error = file.saveError {
                    Text(verbatim: format("markdown.saveError", error))
                        .font(metrics.font(.footnote))
                        .foregroundStyle(theme[.statusStopped])
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(metrics.space(.s))
                }
                TextEditor(text: Bindable(file).draft)
                    .font(metrics.font(.body).monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(metrics.space(.s))
                    .accessibilityIdentifier("markdown.editor")
            }
        } else if let error = file.loadError {
            VStack(spacing: metrics.space(.m)) {
                Text(verbatim: format("markdown.loadError", file.path))
                    .foregroundStyle(theme[.textPrimary])
                Text(verbatim: error)
                    .font(metrics.font(.footnote))
                    .foregroundStyle(theme[.textSecondary])
                Button("markdown.refresh") { file.reload() }
            }
            .multilineTextAlignment(.center)
            .padding(metrics.space(.xl))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("markdown.error")
        } else {
            ScrollView {
                MarkdownBlocksView(blocks: file.blocks)
                    .padding(metrics.space(.xl))
                    .frame(maxWidth: metrics.size(820), alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("markdown.rendered")
        }
    }

    private func copySource() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.source, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
