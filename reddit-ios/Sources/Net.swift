// Reading Reddit. You sign in on Reddit's own page; from that session the app gets a short-lived
// access token the way Reddit's mobile website does, and reads Reddit's authenticated API
// (oauth.reddit.com), which answers normally where plain requests are blocked. Your login and the
// token stay in this app on your iPhone. Pictures are fetched at the size they're shown.

import ImageIO
import UIKit
import WebKit

enum APIError: Error, CustomStringConvertible {
    case http(Int)
    case offline(String)
    case bad

    var description: String {
        switch self {
        case .http(let c) where c == 401 || c == 403: return "Reddit won't show this (\(c)): private, banned, or you need to sign in. Pull down to try again."
        case .http(404): return "Not found."
        case .http(429): return "Reddit says too many requests. Wait a minute and pull down to try again."
        case .http(let c): return "Reddit answered \(c)."
        case .offline(let m): return m
        case .bad: return "Reddit sent something unexpected. Pull down to try again."
        }
    }
}

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func s(_ k: String) -> String { self[k] as? String ?? "" }
    func i(_ k: String) -> Int { (self[k] as? NSNumber)?.intValue ?? 0 }
    func d(_ k: String) -> Double { (self[k] as? NSNumber)?.doubleValue ?? 0 }
    func b(_ k: String) -> Bool { (self[k] as? NSNumber)?.boolValue ?? false }
    func o(_ k: String) -> JSON { self[k] as? JSON ?? [:] }
    func a(_ k: String) -> [JSON] { self[k] as? [JSON] ?? [] }
}

/// The end of Safari's own name for itself on this iPhone (iOS 15.6 and later all say Safari 15.6).
/// Given to the hidden Safari view, which builds the rest exactly as Safari does.
let safariSuffix: String = {
    let parts = UIDevice.current.systemVersion.split(separator: ".").compactMap { Int($0) }
    let major = parts.first ?? 15, minor = parts.count > 1 ? parts[1] : 0
    let version = major == 15 ? "15.\(min(minor, 6))" : "\(major).\(minor)"
    return "Version/\(version) Mobile/15E148 Safari/604.1"
}()

/// What Safari on this iPhone calls itself.
let safariUA: String = {
    let v = UIDevice.current.systemVersion
    let major = v.split(separator: ".").first.map(String.init) ?? "15"
    return "Mozilla/5.0 (iPhone; CPU iPhone OS \(v.replacingOccurrences(of: ".", with: "_")) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).0 Mobile/15E148 Safari/604.1"
}()

/// An app identity for Reddit's API, the way a phone app names itself.
let appUA = "ios:com.yrs.reddit:v1.0 (by /u/yrs)"

/// Reads Reddit through its authenticated API. You sign in on Reddit's own page; from that session
/// the app gets a short-lived access token (the way Reddit's mobile website does) and reads
/// oauth.reddit.com with it — the API path, which isn't behind the block that stops plain requests.
/// Your login cookies and the token stay in this app on your iPhone and go nowhere else.
final class Reddit {
    static let shared = Reddit()
    static let signedIn = Notification.Name("yrs.reddit.signin")
    /// Reddit's own mobile-website client id (public, no secret).
    private static let clientID = "ohXpoqrZYub1kg"

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.httpMaximumConnectionsPerHost = 4
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    private var token: String?
    private var tokenUntil = Date.distantPast
    private var minting = false
    private var waiting: [(String?) -> Void] = []
    /// "user" once a real logged-in token is minted, else "logged-out".
    private var tokenKind = "no"

    /// The `sub` claim inside a Reddit access token (a JWT), to tell a real login from a guest token.
    static func subject(of jwt: String) -> String {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return "" }
        var b = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b), let j = try? JSONSerialization.jsonObject(with: d) as? JSON else { return "" }
        return (j["sub"] as? String) ?? ""
    }

    var isSignedIn: Bool { UserDefaults.standard.bool(forKey: "signedIn") }

    // MARK: addresses

    /// An API address on oauth.reddit.com (no .json; the token says who you are).
    func url(_ path: String, _ q: [String: String] = [:]) -> URL {
        var p = path.hasPrefix("/") ? path : "/" + path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        // a permalink may carry .json already; drop it for the API
        if p.hasSuffix(".json") { p.removeLast(5) }
        var c = URLComponents()
        c.scheme = "https"
        c.host = "oauth.reddit.com"
        c.path = p.isEmpty ? "/" : p
        var items = [URLQueryItem(name: "raw_json", value: "1")]
        items += q.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        c.queryItems = items
        return c.url!
    }

    // MARK: reading

    /// GET some JSON from Reddit's API, with a valid token; the reply on the main queue.
    func get(_ path: String, _ q: [String: String] = [:], done: @escaping (Result<Any, APIError>) -> Void) {
        withToken { [weak self] t in
            guard let s = self else { return }
            guard let t = t else {
                done(.failure(.offline("Sign in to Reddit first (on the home screen).")))
                return
            }
            s.call(path, q, token: t, retry: true, done: done)
        }
    }

    private func call(_ path: String, _ q: [String: String], token: String, retry: Bool, done: @escaping (Result<Any, APIError>) -> Void) {
        var req = URLRequest(url: url(path, q))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(appUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (resp as? HTTPURLResponse) == nil, let err = err {
                DispatchQueue.main.async { done(.failure(.offline((err as NSError).code == NSURLErrorNotConnectedToInternet ? "No internet connection." : err.localizedDescription))) }
                return
            }
            // token expired or rejected: mint a fresh one and try this request once more
            if code == 401, retry {
                self.token = nil
                self.withToken { fresh in
                    if let fresh = fresh { self.call(path, q, token: fresh, retry: false, done: done) }
                    else { DispatchQueue.main.async { done(.failure(.http(401))) } }
                }
                return
            }
            let r: Result<Any, APIError>
            if code == 404 { r = .failure(.http(404)) }
            else if !(200 ..< 300).contains(code) {
                // show exactly what Reddit said, so a failing tab tells us the real reason
                var body = data.flatMap { String(data: $0.prefix(160), encoding: .utf8) } ?? ""
                body = body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                let ep = (self.url(path, q).path)
                r = .failure(.offline("\(ep) → \(code) · \(self.tokenKind) token\(body.isEmpty ? "" : "\nReddit: \(body)")"))
            }
            else if let d = data, let j = try? JSONSerialization.jsonObject(with: d) { r = .success(j) }
            else { r = .failure(.bad) }
            DispatchQueue.main.async { done(r) }
        }.resume()
    }

    // MARK: the token

    /// Gives a fresh token (minting one if needed), or nil if not signed in.
    private func withToken(_ done: @escaping (String?) -> Void) {
        if let t = token, tokenUntil > Date().addingTimeInterval(60) { done(t); return }
        waiting.append(done)
        guard !minting else { return }
        minting = true
        mint { [weak self] t in
            guard let s = self else { return }
            s.minting = false
            let w = s.waiting
            s.waiting = []
            w.forEach { $0(t) }
        }
    }

    /// Exchanges the Reddit login cookies for an access token, as the mobile website does.
    private func mint(_ done: @escaping (String?) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let mine = cookies.filter { $0.domain.hasSuffix("reddit.com") }
            let header = mine.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            guard mine.contains(where: { $0.name == "reddit_session" }) else { DispatchQueue.main.async { done(nil) }; return }
            let basic = Data("\(Reddit.clientID):".utf8).base64EncodedString()
            var req = URLRequest(url: URL(string: "https://accounts.reddit.com/api/access_token")!)
            req.httpMethod = "POST"
            req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
            req.setValue(header, forHTTPHeaderField: "Cookie")
            req.setValue(appUA, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["scopes": ["*"]])
            req.httpShouldHandleCookies = false
            self.session.dataTask(with: req) { data, _, _ in
                var tok: String?
                if let d = data, let j = try? JSONSerialization.jsonObject(with: d) as? JSON, let t = j["access_token"] as? String {
                    tok = t
                    let secs = (j["expires_in"] as? NSNumber)?.doubleValue ?? 3600
                    self.token = t
                    self.tokenUntil = Date().addingTimeInterval(secs)
                    self.tokenKind = Reddit.subject(of: t).hasPrefix("loid") ? "logged-out" : "user"
                }
                DispatchQueue.main.async { done(tok) }
            }.resume()
        }
    }

    // MARK: signing in and out

    func signedIn(_ yes: Bool) {
        UserDefaults.standard.set(yes, forKey: "signedIn")
        token = nil
        tokenUntil = .distantPast
        NotificationCenter.default.post(name: Reddit.signedIn, object: nil)
    }

    func signOut() {
        token = nil
        tokenUntil = .distantPast
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            self?.signedIn(false)
        }
    }
}

// MARK: - pictures

enum Images {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 6_000_000   // a few screens' worth, then the oldest go
        return c
    }()

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 3
        c.httpAdditionalHeaders = ["User-Agent": safariUA, "Accept": "image/jpeg,image/png,image/*;q=0.8"]
        return URLSession(configuration: c)
    }()

    static func forget() { cache.removeAllObjects() }

    /// A picture shrunk to `px` pixels on its longest side.
    @discardableResult
    static func load(_ u: URL, px: CGFloat, done: @escaping (UIImage?) -> Void) -> URLSessionDataTask? {
        get(u, key: "\(Int(px))", make: { downsample($0, px: px) }, done: done)
    }

    /// A square thumbnail, filled to `side` points.
    @discardableResult
    static func thumb(_ u: URL, side: CGFloat, done: @escaping (UIImage?) -> Void) -> URLSessionDataTask? {
        let scale = UIScreen.main.scale
        return get(u, key: "t\(Int(side))", make: { d in
            guard let img = downsample(d, px: side * scale * 2) else { return nil }
            let f = UIGraphicsImageRendererFormat()
            f.scale = scale
            f.opaque = true
            return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: f).image { _ in
                let s = img.size, k = max(side / s.width, side / s.height)
                img.draw(in: CGRect(x: (side - s.width * k) / 2, y: (side - s.height * k) / 2, width: s.width * k, height: s.height * k))
            }
        }, done: done)
    }

    private static func get(_ u: URL, key: String, make: @escaping (Data) -> UIImage?, done: @escaping (UIImage?) -> Void) -> URLSessionDataTask? {
        let k = (key + u.absoluteString) as NSString
        if let i = cache.object(forKey: k) { done(i); return nil }
        let t = session.dataTask(with: u) { data, _, _ in
            let img = data.flatMap { d in autoreleasepool { make(d) } }
            DispatchQueue.main.async {
                if let i = img { cache.setObject(i, forKey: k, cost: Int(i.size.width * i.size.height * i.scale * i.scale * 4)) }
                done(img)
            }
        }
        t.resume()
        return t
    }

    private static func downsample(_ d: Data, px: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(d as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: px,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - words

private let relative: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
}()

func ago(_ unix: Double) -> String {
    unix > 0 ? relative.localizedString(for: Date(timeIntervalSince1970: unix), relativeTo: Date()) : ""
}

func count(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fm", Double(n) / 1_000_000).replacingOccurrences(of: ".0m", with: "m") }
    if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000).replacingOccurrences(of: ".0k", with: "k") }
    return "\(n)"
}

func joined(_ bits: [String]) -> String { bits.filter { !$0.isEmpty }.joined(separator: " · ") }
