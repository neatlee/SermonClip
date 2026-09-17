import SwiftUI

/// Observed only by the field, so keystrokes don't invalidate the project panel.
@MainActor
final class ExportNameDraft: ObservableObject {
    @Published private(set) var text = ""
    private var pendingCommit: (() -> Void)?
    private var task: Task<Void, Never>?

    func replace(with value: String) {
        task?.cancel()
        pendingCommit = nil
        if text != value { text = value }
    }

    func edit(_ value: String, delay: Duration = .milliseconds(250), commit: @escaping (String) -> Void) {
        text = value
        task?.cancel()
        pendingCommit = { commit(value) }
        task = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        task?.cancel()
        task = nil
        let commit = pendingCommit
        pendingCommit = nil
        commit?()
    }
}

struct ExportNameEditor: View {
    @ObservedObject var draft: ExportNameDraft
    var commit: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name for Exported Files", text: Binding(
            get: { draft.text },
            set: { draft.edit($0, commit: commit) }
        ))
        .sermonClipInputStyle()
        .focused($focused)
        .onSubmit { draft.flush() }
        .onChange(of: focused) { _, focused in if !focused { draft.flush() } }
        .onDisappear { draft.flush() }
    }
}
