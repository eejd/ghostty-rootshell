import SwiftUI

/// This delegate is notified of the completion result of the clipboard confirmation dialog.
protocol ClipboardConfirmationViewDelegate: AnyObject {
    func clipboardConfirmationComplete(_ action: ClipboardConfirmationView.Action, _ reason: Ghostty.ClipboardPromptReason)
}

/// The SwiftUI view for showing a clipboard confirmation dialog.
struct ClipboardConfirmationView: View {
    enum Action : String {
        case cancel
        case confirm

        static func text(_ action: Action, _ reason: Ghostty.ClipboardPromptReason) -> String {
            switch (action) {
            case .cancel:
                switch (reason) {
                case .unsafe: return "Cancel"
                case .read, .write: return "Deny"
                }
            case .confirm:
                switch (reason) {
                case .unsafe: return "Paste"
                case .read, .write: return "Allow"
                }
            }
        }
    }

    /// The contents of the paste.
    let contents: String

    /// The reason for displaying the view
    let reason: Ghostty.ClipboardPromptReason

    /// Optional delegate to get results. If this is nil, then this view will never close on its own.
    weak var delegate: ClipboardConfirmationViewDelegate? = nil

    var body: some View {
        VStack {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 42))
                    .padding()
                    .frame(alignment: .center)

                Text(reason.text())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            TextEditor(text: .constant(contents))
                .textSelection(.enabled)
                .font(.system(.body, design: .monospaced))
                .padding(.all, 4)

            HStack {
                Spacer()
                Button(Action.text(.cancel, reason)) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(Action.text(.confirm, reason)) { onPaste() }
                    .keyboardShortcut(.defaultAction)
                Spacer()
            }
            .padding(.bottom)
        }
    }

    private func onCancel() {
        delegate?.clipboardConfirmationComplete(.cancel, reason)
    }

    private func onPaste() {
        delegate?.clipboardConfirmationComplete(.confirm, reason)
    }
}
