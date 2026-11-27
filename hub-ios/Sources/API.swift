// Talking to GitHub, signed out — public GitHub only. GitHub's no-login limit is 60 requests an hour
// (per network IP) for the core API, plus 10 searches a minute. Replies are cached on disk for a short
// while, so re-opening a repo, a README or a release list costs nothing and the scarce hourly budget
// stretches much further. No token, no account, no tracking.

import Foundation

enum APIError: Error, CustomStringConvertible {
    case http(Int, String)
    case offline(String)
    case bad

    var description: String {
        switch self {
        case .http(403, let m) where m.lowercased().contains("rate limit") || m.isEmpty:
            return "GitHub's no-login limit (60/hour, shared across your network) is used up. Try again \(RateLimit.resetText)."
        case .http(429, _): return "GitHub is asking you to slow down. Wait a minute and pull down to retry."
        case .http(404, _): return "Not found, or private."
        case .http(let c, let m): return m.isEmpty ? "GitHub answered \(c)." : m
        case .offline(let m): return m
        case .bad: return "GitHub sent something unexpected."
        }
    }
}

/// What's left of the no-login hourly budget, read from GitHub's reply headers.
enum RateLimit {
    static var coreRemaining: Int?
    static var coreReset: Date?
    static var searchRemaining: Int?

    static func capture(_ h: HTTPURLResponse) {
        guard let remS = h.value(forHTTPHeaderField: "x-ratelimit-remaining"), let rem = Int(remS) else { return }
        let reset = h.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
        if (h.value(forHTTPHeaderField: "x-ratelimit-resource") ?? "core") == "search" { searchRemaining = rem }
        else { coreRemaining = rem; coreReset = reset }
    }

    /// "in about 12 min", for the friendly limit message.
    static var resetText: String {
        guard let d = coreReset else { return "in a little while" }
        let s = Int(d.timeIntervalSinceNow)
        if s <= 0 { return "now" }
        return s < 90 ? "in under a minute" : "in about \(Int(round(Double(s) / 60))) min"
    }
}

final class API {
    static let shared = API()
    static let base = URL(string: "https://api.github.com")!

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 2    // serial-ish, to stay clear of secondary limits
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["User-Agent": "yrs-hub", "X-GitHub-Api-Version": "2022-11-28"]
        return URLSession(configuration: c)
    }()

    // MARK: requests

    func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        if path.hasPrefix("http"), let u = URL(string: path) { return add(query, to: u) }
        return add(query, to: API.base.appendingPathComponent(path))
    }

    private func add(_ q: [String: String], to u: URL) -> URL {
        guard !q.isEmpty, var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return u }
        c.queryItems = (c.queryItems ?? []) + q.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url ?? u
    }

    /// GET some JSON; `cache` seconds serves a fresh on-disk copy without spending the hourly budget.
    func json(_ path: String, _ query: [String: String] = [:], cache: TimeInterval = 0, done: @escaping (Result<Any, APIError>) -> Void) {
        send(url(path, query), accept: "application/vnd.github+json", cache: cache) { r in
            done(r.flatMap { data in
                guard let j = try? JSONSerialization.jsonObject(with: data) else { return .failure(.bad) }
                return .success(j)
            })
        }
    }

    /// GET a file or README as plain text (raw); nil text for a binary file.
    func raw(_ path: String, _ query: [String: String] = [:], cache: TimeInterval = 0, done: @escaping (Result<String?, APIError>) -> Void) {
        send(url(path, query), accept: "application/vnd.github.raw", cache: cache) { r in
            done(r.map { data in
                if data.prefix(4096).contains(0) { return nil }
                return String(decoding: data, as: UTF8.self)
            })
        }
    }

    private func send(_ u: URL, accept: String, cache: TimeInterval, done: @escaping (Result<Data, APIError>) -> Void) {
        let key = accept + "\n" + u.absoluteString
        if cache > 0, let d = DiskCache.read(key, maxAge: cache) { done(.success(d)); return }   // free, from disk
        var req = URLRequest(url: u)
        req.setValue(accept, forHTTPHeaderField: "Accept")
        session.dataTask(with: req) { data, resp, err in
            if let h = resp as? HTTPURLResponse { RateLimit.capture(h) }
            let r: Result<Data, APIError>
            if let err = err {
                r = .failure(.offline((err as NSError).code == NSURLErrorNotConnectedToInternet ? "No internet connection." : err.localizedDescription))
            } else if let h = resp as? HTTPURLResponse, !(200 ..< 300).contains(h.statusCode) {
                let msg = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["message"] as? String ?? ""
                r = .failure(.http(h.statusCode, msg))
            } else {
                let d = data ?? Data()
                if cache > 0 { DiskCache.write(key, d) }
                r = .success(d)
            }
            DispatchQueue.main.async { done(r) }
        }.resume()
    }
}

/// A short-lived on-disk cache of GitHub replies, so re-opening things is instant and free.
enum DiskCache {
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let d = base.appendingPathComponent("yrs-hub", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static func file(_ key: String) -> URL {
        var h: UInt64 = 14695981039346656037          // FNV-1a — a stable name for this key
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return dir.appendingPathComponent(String(h, radix: 16) + ".cache")
    }

    static func read(_ key: String, maxAge: TimeInterval) -> Data? {
        let f = file(key)
        guard let m = (try? FileManager.default.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date,
              Date().timeIntervalSince(m) < maxAge else { return nil }
        return try? Data(contentsOf: f)
    }

    static func write(_ key: String, _ data: Data) { try? data.write(to: file(key), options: .atomic) }
}

// MARK: - reading the JSON

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func s(_ k: String) -> String { self[k] as? String ?? "" }
    func i(_ k: String) -> Int { self[k] as? Int ?? 0 }
    func o(_ k: String) -> JSON { self[k] as? JSON ?? [:] }
}

private let isoParser: ISO8601DateFormatter = ISO8601DateFormatter()
private let relative: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
}()

/// "3 days ago", from GitHub's timestamps.
func ago(_ iso: String) -> String {
    guard let d = isoParser.date(from: iso) else { return "" }
    return relative.localizedString(for: d, relativeTo: Date())
}

func count(_ n: Int) -> String {
    n >= 1000 ? String(format: "%.1fk", Double(n) / 1000).replacingOccurrences(of: ".0k", with: "k") : "\(n)"
}
