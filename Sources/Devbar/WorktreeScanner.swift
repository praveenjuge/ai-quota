import Foundation

/// One linked git worktree (never a repository's main checkout).
struct Worktree: Identifiable, Sendable, Hashable {
    var path: String
    /// The repository's shared `.git` directory, which git commands run against.
    var commonDirectory: String
    var repository: String
    /// Short branch name, or nil when HEAD is detached.
    var branch: String?
    var isLocked: Bool
    /// The folder is gone; deleting only drops git's record of it.
    var isMissing: Bool
    var hasChanges: Bool
    /// Everything on the branch is already in the default branch, so
    /// deleting it loses nothing.
    var isMerged: Bool
    /// Default-branch refs the branch is checked against.
    var mergeTargets: [String]
    var lastActive: Date

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }

    static let staleAge: TimeInterval = 7 * 86400

    /// Untouched for a week. Locked worktrees are in use (Claude Code locks
    /// its own while an agent runs), so they never count as stale.
    var isStale: Bool { !isLocked && lastActive < Date(timeIntervalSinceNow: -Self.staleAge) }
}

/// Finds linked worktrees in the home folder: walks it for repositories,
/// then asks git for each one's worktrees (`git worktree list --porcelain`).
/// Spotlight doesn't index `.git`, so a bounded walk is the only way.
enum WorktreeScanner {
    static func scan() async -> [Worktree] {
        let commonDirectories = await Task.detached(priority: .userInitiated) {
            repositories(in: FileManager.default.homeDirectoryForCurrentUser)
        }.value
        return await withTaskGroup(of: [Worktree].self) { group in
            for directory in commonDirectories {
                group.addTask { await worktrees(of: directory) }
            }
            var all: [Worktree] = []
            for await worktrees in group { all += worktrees }
            return all
        }
    }

    /// Deletes the folder, uncommitted changes included, and git's record of
    /// it. Double force also removes locked worktrees. The branch goes too
    /// only when asked and still merged; otherwise committed work stays.
    static func delete(_ worktree: Worktree, deleteMergedBranch: Bool) async throws {
        let result = await git(["worktree", "remove", "--force", "--force", worktree.path], in: worktree.commonDirectory)
        if result.status != 0 { throw DeleteError(message: result.error) }
        guard deleteMergedBranch, let branch = worktree.branch,
              // The branch may have moved since the scan; check again.
              await isMerged(branch, into: worktree.mergeTargets, in: worktree.commonDirectory) else { return }
        // -D because squash merges don't count as merged to `git branch -d`.
        let branchResult = await git(["branch", "-D", branch], in: worktree.commonDirectory)
        if branchResult.status != 0 {
            throw DeleteError(message: "Deleted the worktree but not its branch. \(branchResult.error)")
        }
    }

    struct DeleteError: LocalizedError {
        var message: String
        var errorDescription: String? { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - Finding repositories

    /// Folders that never hold projects, or are huge, or ask for permission.
    private static let skipped: Set<String> = [
        "Library", "Applications", "Pictures", "Music", "Movies",
        "node_modules", "Pods", "DerivedData", "build", "dist", "vendor",
    ]
    private static let maxDepth = 8

    /// Shared `.git` directories of every repository that has worktrees.
    private static func repositories(in root: URL) -> Set<String> {
        var found = Set<String>()
        walk(root, depth: 0, found: &found)
        return found
    }

    private static func walk(_ directory: URL, depth: Int, found: inout Set<String>) {
        let fm = FileManager.default
        let dotGit = directory.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
            let common = isDirectory.boolValue ? dotGit.path : commonDirectory(ofGitFile: dotGit)
            if let common, hasWorktrees(common) { found.insert(common) }
            // Worktrees nested in a repo are listed by that repo.
            return
        }
        // Bare repositories, e.g. `project.git` or `project/.bare`.
        if fm.fileExists(atPath: directory.appendingPathComponent("HEAD").path),
           fm.fileExists(atPath: directory.appendingPathComponent("objects").path) {
            if hasWorktrees(directory.path) { found.insert(directory.path) }
            return
        }
        guard depth < maxDepth,
              let children = try? fm.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                  options: [.skipsHiddenFiles]
              ) else { return }
        for child in children where !skipped.contains(child.lastPathComponent) {
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]),
                  values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true else { continue }
            walk(child, depth: depth + 1, found: &found)
        }
    }

    /// A `.git` file reads `gitdir: <path>`. In a linked worktree that path
    /// has a `commondir` pointing back to the shared directory.
    private static func commonDirectory(ofGitFile file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let gitDirectory = resolve(line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces), from: file.deletingLastPathComponent())
        guard let common = try? String(contentsOf: gitDirectory.appendingPathComponent("commondir"), encoding: .utf8) else {
            return gitDirectory.path
        }
        return resolve(common.trimmingCharacters(in: .whitespacesAndNewlines), from: gitDirectory).path
    }

    private static func resolve(_ path: String, from base: URL) -> URL {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
        return url.standardizedFileURL
    }

    private static func hasWorktrees(_ commonDirectory: String) -> Bool {
        let entries = try? FileManager.default.contentsOfDirectory(atPath: commonDirectory + "/worktrees")
        return entries?.isEmpty == false
    }

    // MARK: - Listing worktrees

    private static func worktrees(of commonDirectory: String) async -> [Worktree] {
        let result = await git(["worktree", "list", "--porcelain", "-z"], in: commonDirectory)
        guard result.status == 0 else { return [] }
        // Records are NUL-separated lines, with an empty line between
        // worktrees. The first record is always the main checkout.
        let records = result.output.components(separatedBy: "\0\0").map { $0.components(separatedBy: "\0") }
        guard let main = records.first?.first(where: { $0.hasPrefix("worktree ") })?.dropFirst("worktree ".count) else { return [] }
        let repository = commonDirectory.hasSuffix("/.git") ? (String(main) as NSString).lastPathComponent
            : ((commonDirectory as NSString).lastPathComponent as NSString).deletingPathExtension
        let adminDirectories = adminDirectoriesByPath(commonDirectory)
        let mergeTargets = await defaultBranches(of: commonDirectory)

        var worktrees: [Worktree] = []
        for record in records.dropFirst() {
            var path: String?
            var branch: String?
            var isLocked = false
            var isMissing = false
            for field in record {
                if field.hasPrefix("worktree ") { path = String(field.dropFirst("worktree ".count)) }
                if field.hasPrefix("branch ") { branch = String(field.dropFirst("branch refs/heads/".count)) }
                if field == "locked" || field.hasPrefix("locked ") { isLocked = true }
                if field == "prunable" || field.hasPrefix("prunable ") { isMissing = true }
            }
            guard let path, !record.contains("bare") else { continue }
            let hasChanges = isMissing ? false : await isDirty(path)
            let isMerged = if let branch { await isMerged(branch, into: mergeTargets, in: commonDirectory) } else { false }
            worktrees.append(Worktree(
                path: path,
                commonDirectory: commonDirectory,
                repository: repository,
                branch: branch,
                isLocked: isLocked,
                isMissing: isMissing,
                hasChanges: hasChanges,
                isMerged: isMerged,
                mergeTargets: mergeTargets,
                lastActive: lastActive(path: path, admin: adminDirectories[path], isMissing: isMissing)
            ))
        }
        return worktrees
    }

    /// Maps each worktree folder to its `<common>/worktrees/<name>` directory,
    /// whose `gitdir` file holds `<folder>/.git`.
    private static func adminDirectoriesByPath(_ commonDirectory: String) -> [String: String] {
        let root = commonDirectory + "/worktrees"
        var map: [String: String] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            let admin = root + "/" + name
            guard let gitdir = try? String(contentsOfFile: admin + "/gitdir", encoding: .utf8) else { continue }
            let dotGit = resolve(gitdir.trimmingCharacters(in: .whitespacesAndNewlines), from: URL(fileURLWithPath: admin))
            map[dotGit.deletingLastPathComponent().path] = admin
        }
        return map
    }

    /// Git touches HEAD, the index, and the HEAD log on checkout, status,
    /// staging, and commits; the folder itself changes when files come and go.
    private static func lastActive(path: String, admin: String?, isMissing: Bool) -> Date {
        var candidates = isMissing ? [] : [path]
        if let admin { candidates += ["HEAD", "index", "logs/HEAD"].map { admin + "/" + $0 } }
        let dates = candidates.compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }
        return dates.max() ?? .distantPast
    }

    /// Tracked edits or untracked files. Optional locks stay off so checking
    /// never rewrites the index, which would count as activity.
    private static func isDirty(_ path: String) async -> Bool {
        let result = await git(["-C", path, "status", "--porcelain"], in: nil)
        return result.status == 0 && !result.output.isEmpty
    }

    // MARK: - Merged branches

    /// The main checkout's branch (HEAD of the shared directory) and the
    /// remote's default branch, which may be ahead of the local one.
    private static func defaultBranches(of commonDirectory: String) async -> [String] {
        var refs: [String] = []
        for symbolicRef in ["HEAD", "refs/remotes/origin/HEAD"] {
            let result = await git(["symbolic-ref", "-q", symbolicRef], in: commonDirectory)
            let ref = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.status == 0, !ref.isEmpty { refs.append(ref) }
        }
        return refs
    }

    /// Merged when merging the branch into a default branch would change
    /// nothing: true for regular, rebase, and squash merges, and for
    /// branches with no commits of their own. Never true for a default
    /// branch itself.
    private static func isMerged(_ branch: String, into targets: [String], in commonDirectory: String) async -> Bool {
        let ref = "refs/heads/\(branch)"
        let defaultNames = targets.map { ($0 as NSString).lastPathComponent }
        guard !targets.contains(ref), !defaultNames.contains(branch) else { return false }
        for target in targets {
            if await git(["merge-base", "--is-ancestor", ref, target], in: commonDirectory).status == 0 { return true }
            // Writes the merged tree to compare it; unchanged means merged.
            let merge = await git(["merge-tree", "--write-tree", "--no-messages", target, ref], in: commonDirectory)
            let targetTree = await git(["rev-parse", "\(target)^{tree}"], in: commonDirectory)
            let mergedTree = merge.output.split(separator: "\n").first.map(String.init)
            if merge.status == 0, targetTree.status == 0,
               mergedTree == targetTree.output.trimmingCharacters(in: .whitespacesAndNewlines) { return true }
        }
        return false
    }

    // MARK: - Running git

    /// Apps launched from Finder get a bare PATH; prefer a newer git when installed.
    private static let gitPath = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"

    private static func git(_ arguments: [String], in commonDirectory: String?) async -> (status: Int32, output: String, error: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: gitPath)
                process.arguments = (commonDirectory.map { ["--git-dir=\($0)"] } ?? []) + arguments
                var environment = ProcessInfo.processInfo.environment
                environment["GIT_OPTIONAL_LOCKS"] = "0"
                environment["GIT_TERMINAL_PROMPT"] = "0"
                process.environment = environment
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    return continuation.resume(returning: (-1, "", error.localizedDescription))
                }
                // Git's messages are short, so reading them second can't stall it.
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (
                    process.terminationStatus,
                    String(decoding: data, as: UTF8.self),
                    String(decoding: errorData, as: UTF8.self)
                ))
            }
        }
    }
}
