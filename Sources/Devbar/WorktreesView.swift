import AppKit
import SwiftUI

/// Worktrees found on this Mac. Scans only while the window is open.
@MainActor
@Observable
final class WorktreeStore {
    private(set) var worktrees: [Worktree] = []
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var deleting: Set<String> = []
    var failure: String?

    /// Repositories by name, most recently used worktrees first.
    var groups: [(repository: String, worktrees: [Worktree])] {
        Dictionary(grouping: worktrees, by: \.repository)
            .map { ($0.key, $0.value.sorted { $0.lastActive > $1.lastActive }) }
            .sorted { $0.repository.localizedStandardCompare($1.repository) == .orderedAscending }
    }

    var stale: [Worktree] { worktrees.filter(\.isStale) }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        worktrees = await WorktreeScanner.scan()
        isScanning = false
        hasScanned = true
    }

    func delete(_ targets: [Worktree], deleteMergedBranches: Bool) async {
        var errors: [String] = []
        for worktree in targets {
            deleting.insert(worktree.id)
            do {
                try await WorktreeScanner.delete(worktree, deleteMergedBranch: deleteMergedBranches)
                worktrees.removeAll { $0.id == worktree.id }
            } catch {
                errors.append("\(worktree.name): \(error.localizedDescription)")
            }
            deleting.remove(worktree.id)
        }
        guard !errors.isEmpty else { return }
        failure = errors.joined(separator: "\n")
        // A failed removal can still get partway, so show what's left.
        await scan()
    }
}

struct WorktreesView: View {
    let store: WorktreeStore
    @State private var pendingDelete: [Worktree] = []
    @AppStorage("worktrees.deleteMergedBranches") private var deleteMergedBranches = true

    var body: some View {
        content
            .frame(minWidth: 460, idealWidth: 500, minHeight: 280, idealHeight: 440)
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .alert(deleteTitle, isPresented: confirming) {
                Button("Delete", role: .destructive) {
                    let targets = pendingDelete
                    let deleteBranches = deleteMergedBranches
                    Task { await store.delete(targets, deleteMergedBranches: deleteBranches) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteMessage)
            }
            .alert("Couldn't Delete", isPresented: failed) {
                Button("OK") {}
            } message: {
                Text(store.failure ?? "")
            }
    }

    @ViewBuilder private var content: some View {
        if !store.hasScanned {
            ProgressView("Looking for worktrees…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.worktrees.isEmpty {
            ContentUnavailableView(
                "No Worktrees",
                systemImage: "arrow.triangle.branch",
                description: Text("Git worktrees in your home folder show up here.")
            )
        } else {
            List {
                ForEach(store.groups, id: \.repository) { group in
                    Section(group.repository) {
                        ForEach(group.worktrees) { worktree in
                            WorktreeRow(worktree: worktree, isDeleting: store.deleting.contains(worktree.id)) {
                                pendingDelete = [worktree]
                            }
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                Task { await store.scan() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .help("Look for worktrees again")
            .disabled(store.isScanning)
            if store.isScanning && store.hasScanned {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Toggle("Delete merged branches", isOn: $deleteMergedBranches)
                .help("When deleting a worktree, also delete its branch if everything on it is already in the default branch")
            Button("Delete Older Than a Week") { pendingDelete = store.stale }
                .disabled(store.stale.isEmpty || store.isScanning)
                .help("Locked worktrees are skipped")
        }
        .padding(10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var confirming: Binding<Bool> {
        Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })
    }

    private var failed: Binding<Bool> {
        Binding(get: { store.failure != nil }, set: { if !$0 { store.failure = nil } })
    }

    private var deleteTitle: String {
        if pendingDelete.count == 1, let worktree = pendingDelete.first {
            return "Delete \u{201C}\(worktree.name)\u{201D}?"
        }
        return "Delete \(pendingDelete.count) worktrees not used in the last week?"
    }

    /// What happens to branches, so nobody is surprised a branch is gone.
    private var branchMessage: String {
        let merged = deleteMergedBranches ? pendingDelete.filter(\.isMerged) : []
        if pendingDelete.count == 1, let branch = pendingDelete[0].branch {
            return merged.isEmpty
                ? "Its branch \u{201C}\(branch)\u{201D} is kept, so committed work stays in the repository."
                : "Its branch \u{201C}\(branch)\u{201D} is already merged, so it's deleted too."
        }
        if pendingDelete.count == 1 { return "" }
        if merged.isEmpty { return "Branches are kept, so committed work stays in the repository." }
        let count = merged.count == 1 ? "1 merged branch is" : "\(merged.count) merged branches are"
        return "\(count) deleted too. Other branches are kept."
    }

    private var deleteMessage: String {
        let single = pendingDelete.count == 1
        var lines = [((single ? "The folder is" : "Their folders are") + " permanently deleted. " + branchMessage)
            .trimmingCharacters(in: .whitespaces)]
        let changed = pendingDelete.filter(\.hasChanges).count
        if single, changed == 1 {
            lines.append("It has uncommitted changes, which will be lost.")
        } else if changed > 0 {
            lines.append("\(changed) of them \(changed == 1 ? "has" : "have") uncommitted changes, which will be lost.")
        }
        if single, pendingDelete[0].isLocked {
            lines.append("It's locked, so an app may still be using it.")
        }
        return lines.joined(separator: "\n\n")
    }
}

private struct WorktreeRow: View {
    let worktree: Worktree
    let isDeleting: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(worktree.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(worktree.path)
            Spacer()
            if worktree.isLocked {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("Locked: an app may be using it")
                    .accessibilityLabel("Locked")
            }
            if worktree.hasChanges {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.orange)
                    .help("Uncommitted changes")
                    .accessibilityLabel("Uncommitted changes")
            }
            if isDeleting {
                ProgressView().controlSize(.small)
            } else {
                Button(action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Delete worktree")
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)])
            }
            .disabled(worktree.isMissing)
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(worktree.path, forType: .string)
            }
        }
    }

    private var detail: String {
        var branch = worktree.branch ?? "detached"
        if worktree.isMerged { branch += " · merged" }
        if worktree.isMissing { return "\(branch) · Folder missing" }
        let age = worktree.lastActive.formatted(.relative(presentation: .named))
        return "\(branch) · \(age)"
    }
}

/// The one Worktrees window, created on first use and reused after. Every
/// open rescans, so the list matches the disk.
@MainActor
final class WorktreesWindow {
    private var window: NSWindow?
    private var store: WorktreeStore?

    func show() {
        let store = self.store ?? WorktreeStore()
        self.store = store
        let window = self.window ?? makeWindow(store: store)
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Task { await store.scan() }
    }

    private func makeWindow(store: WorktreeStore) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: WorktreesView(store: store)))
        window.title = "Worktrees"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 500, height: 440))
        // Open on the Space the menu was used from, even over a full-screen app.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        return window
    }
}
