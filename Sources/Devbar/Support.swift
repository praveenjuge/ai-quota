import Foundation

/// Defensive JSON extraction. Vendor endpoints are undocumented and drift;
/// every lookup returns nil instead of throwing so one new field shape can
/// never take down a whole provider.
enum JSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func text(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }

    static func dict(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    /// Accepts ISO-8601 strings, unix seconds, or unix milliseconds.
    static func date(_ value: Any?) -> Date? {
        if let s = text(value) {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: s) { return d }
            return nil
        }
        guard let n = number(value), n.isFinite, n > 0 else { return nil }
        let seconds = n < 1e11 ? n : n / 1000
        guard seconds < 64_092_211_200 else { return nil } // year 4000 sanity cap
        return Date(timeIntervalSince1970: seconds)
    }
}

enum Home {
    static func file(_ path: String) -> Data? {
        let expanded = (path as NSString).expandingTildeInPath
        return try? Data(contentsOf: URL(fileURLWithPath: expanded))
    }

    static func env(_ name: String) -> String? {
        guard let v = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !v.isEmpty else { return nil }
        return v
    }
}

enum HTTP {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    struct Response {
        var status: Int
        var body: Data
    }

    static func send(_ request: URLRequest) async throws -> Response {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return Response(status: http.statusCode, body: data)
        } catch let e as URLError {
            throw e
        }
    }

    static func get(_ url: URL, headers: [String: String]) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        headers.forEach { r.setValue($0.value, forHTTPHeaderField: $0.key) }
        return r
    }

    static func postJSON(_ url: URL, headers: [String: String], json: [String: Any] = [:]) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { r.setValue($0.value, forHTTPHeaderField: $0.key) }
        r.httpBody = try? JSONSerialization.data(withJSONObject: json)
        return r
    }
}
