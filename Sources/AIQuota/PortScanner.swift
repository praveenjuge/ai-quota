import Darwin
import Foundation

/// One TCP port a dev server is listening on.
struct ListeningPort: Sendable, Equatable {
    var port: Int
    var pid: pid_t
    var process: String
    /// Working directory the process was started from: the project folder.
    var directory: String

    var project: String { (directory as NSString).lastPathComponent }
    var url: URL { URL(string: "http://localhost:\(port)")! }
}

/// Lists dev servers: TCP listeners started from a project folder. A GUI
/// for `lsof -iTCP -sTCP:LISTEN`, filtered so system services and apps
/// (launched with `/` or their own bundle as working directory) stay out.
enum PortScanner {
    /// Runs `lsof` off the main thread (~40 ms).
    static func scan(hidden: Set<String>) async -> [ListeningPort] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: scanBlocking(hidden: hidden))
            }
        }
    }

    static func scanBlocking(hidden: Set<String>) -> [ListeningPort] {
        guard let output = lsof() else { return [] }
        var ports: [ListeningPort] = []
        var seen = Set<String>()
        var directories: [pid_t: String?] = [:]
        var pid: pid_t = 0
        var command = ""
        // Field output: `p<pid>` and `c<command>` open a process, then one
        // `f<fd>` + `n<address>` pair per socket, e.g. `n[::1]:5173`.
        for line in output.split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": pid = pid_t(value) ?? 0
            case "c": command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]),
                      pid > 0, !hidden.contains(command),
                      seen.insert("\(pid):\(port)").inserted else { continue }
                if directories[pid] == nil { directories[pid] = devDirectory(pid) }
                guard let directory = directories[pid] ?? nil else { continue }
                ports.append(ListeningPort(port: port, pid: pid, process: command, directory: directory))
            default: break
            }
        }
        return ports.sorted { $0.port < $1.port }
    }

    /// SIGTERM asks the server to shut down cleanly; SIGKILL can't be ignored.
    static func stop(_ port: ListeningPort, force: Bool) {
        kill(port.pid, force ? SIGKILL : SIGTERM)
    }

    private static func lsof() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // -n/-P skip DNS and service-name lookups; +c0 keeps full command names.
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "+c0", "-F", "pcn"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // lsof exits 1 when nothing matches; the output is then just empty.
        return String(data: data, encoding: .utf8)
    }

    /// The project folder a dev server runs in, or nil for system services
    /// and apps, which launchd starts in `/` or inside their app bundle.
    private static func devDirectory(_ pid: pid_t) -> String? {
        guard let executable = executablePath(pid),
              !["/System/", "/usr/libexec/", "/usr/sbin/"].contains(where: executable.hasPrefix),
              let directory = workingDirectory(pid),
              directory != "/", !directory.contains(".app/") else { return nil }
        return directory
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : path
    }
}
