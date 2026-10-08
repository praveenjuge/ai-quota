import Foundation
import LocalAuthentication
import Security

enum KeychainError: Error, Sendable {
    case notFound
    case accessDenied
}

/// A generic-password item's public attributes; never its secret.
struct KeychainItem: Sendable, Equatable {
    var service: String
    var modified: Date
}

/// Read-only Keychain access through the /usr/bin/security subprocess (the
/// OpenUsage approach): a macOS approval prompt — if one appears at all — is
/// attributed to Apple's stable binary, so one "Always Allow" sticks forever
/// instead of re-appearing every time this app is rebuilt. This type never
/// writes, and callers never log what it returns.
enum Keychain {
    /// Item-absent exit code of `security find-generic-password` (44).
    private static let itemNotFoundExitCode: Int32 = 44

    /// Reads a generic-password item off the cooperative thread pool (a first
    /// approval prompt can take a while). Returns nil when absent; throws
    /// .accessDenied on deny/cancel/timeout so the caller can show guidance
    /// instead of misreporting "not logged in".
    static func read(service: String, account: String, timeout: TimeInterval) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try readBlocking(service: service, account: account, timeout: timeout) })
            }
        }
    }

    /// Lists generic-password items whose service starts with `servicePrefix`,
    /// newest modification first. Attributes only — no secret is decrypted,
    /// so this never shows an approval prompt and is safe in the background.
    static func items(servicePrefix: String, account: String) -> [KeychainItem] {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]] else { return [] }
        var newest: [String: Date] = [:]
        for row in rows {
            guard let service = row[kSecAttrService as String] as? String,
                  service.hasPrefix(servicePrefix) else { continue }
            let modified = row[kSecAttrModificationDate as String] as? Date
                ?? row[kSecAttrCreationDate as String] as? Date
                ?? .distantPast
            newest[service] = max(newest[service] ?? .distantPast, modified)
        }
        return newest.map { KeychainItem(service: $0.key, modified: $0.value) }
            .sorted { $0.modified > $1.modified }
    }

    private static func readBlocking(service: String, account: String, timeout: TimeInterval) throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", account, "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw KeychainError.accessDenied
        }
        // Bounded wait: a stuck approval prompt must fail the refresh, not hang it.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw KeychainError.accessDenied
        }
        if process.terminationStatus == itemNotFoundExitCode { return nil }
        guard process.terminationStatus == 0 else { throw KeychainError.accessDenied }
        let raw = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: raw, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            text.isEmpty == false else { return nil }
        return Data(text.utf8)
    }
}

/// In-memory cache of Keychain blobs for the process lifetime, so refreshes
/// reuse the token without touching the Keychain again. Cleared per provider
/// when its API rejects the token (external rotation), forcing one silent
/// re-read on the next refresh.
actor CredentialCache {
    static let shared = CredentialCache()
    private var blobs: [String: Data] = [:]

    func get(_ key: String) -> Data? { blobs[key] }
    func set(_ key: String, _ data: Data) { blobs[key] = data }
    func clearAll() { blobs.removeAll() }
}
