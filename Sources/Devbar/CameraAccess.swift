import AppKit
import SQLite3

/// One app in Privacy & Security → Camera.
struct CameraApp: Sendable, Equatable {
    enum Status: Sendable { case allowed, denied, asksNextTime }

    var bundleID: String
    var name: String
    var path: String
    var status: Status
}

/// Camera permissions, read from the user's privacy database. macOS only
/// lets other apps revoke a decision (`tccutil reset`), never grant one:
/// the app asks again the next time it uses the camera.
enum CameraAccess {
    enum Scan: Sendable, Equatable {
        case apps([CameraApp])
        /// The privacy database is readable only with Full Disk Access.
        case needsFullDiskAccess
        case failed
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    private static let databasePath = ("~/Library/Application Support/com.apple.TCC/TCC.db" as NSString).expandingTildeInPath
    private static let knownAppsKey = "camera.knownApps"

    /// Reads the database off the main thread (a few ms).
    static func scan() async -> Scan {
        let known = UserDefaults.standard.stringArray(forKey: knownAppsKey) ?? []
        let scan = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: scanBlocking(known: known))
            }
        }
        // A reset drops the app's row, so remember every app seen: it stays
        // in the menu as "asks next time" instead of disappearing.
        if case .apps(let apps) = scan {
            UserDefaults.standard.set(apps.map(\.bundleID).sorted(), forKey: knownAppsKey)
        }
        return scan
    }

    static func scanBlocking(known: [String]) -> Scan {
        guard let rows = decisions() else {
            // TCC blocks open(2) with EPERM until Full Disk Access is granted.
            let fd = open(databasePath, O_RDONLY)
            if fd >= 0 { close(fd) }
            return fd < 0 && errno == EPERM ? .needsFullDiskAccess : .failed
        }
        var apps: [CameraApp] = []
        for bundleID in Set(rows.keys).union(known) {
            // Apps that were deleted keep their rows; leave them out.
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            let status: CameraApp.Status = switch rows[bundleID] {
            case nil: .asksNextTime
            case 2?: .allowed
            default: .denied
            }
            let name = (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
            apps.append(CameraApp(bundleID: bundleID, name: name, path: url.path, status: status))
        }
        return .apps(apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    /// Clears the app's decision. Returns false if `tccutil` failed.
    static func revoke(_ app: CameraApp) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                process.arguments = ["reset", "Camera", app.bundleID]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { return continuation.resume(returning: false) }
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0)
            }
        }
    }

    /// Bundle ID → `auth_value` (0 denied, 2 allowed) for every app with a
    /// camera decision, or nil when the database can't be read.
    private static func decisions() -> [String: Int]? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        // client_type 0 is a bundle ID; 1 is a bare executable path, which
        // `tccutil` can't reset.
        let sql = "SELECT client, auth_value FROM access WHERE service = 'kTCCServiceCamera' AND client_type = 0"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        var rows: [String: Int] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let client = sqlite3_column_text(statement, 0) else { continue }
                rows[String(cString: client)] = Int(sqlite3_column_int(statement, 1))
            case SQLITE_DONE:
                return rows
            default:
                return nil
            }
        }
    }
}
