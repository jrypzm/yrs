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

/// Reads Reddit through its API (oauth.reddit.com). To be let in, the app loads reddit.com in a
/// plain HTTP request (Reddit's logged-out "installed_client" grant), with no browser and no
/// JavaScript, so iOS 15 handles it. That token reads all public content. No account, nothing stored.
let appUA = "ios:com.yrs.reddit:v1.0 (by /u/yrs_app)"

final class Reddit {
    static let shared = Reddit()
    static let signedIn = Notification.Name("yrs.reddit.signin")

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

    // MARK: addresses

    /// An API address on oauth.reddit.com (no .json; the token says who you are).
    func url(_ path: String, _ q: [String: String] = [:]) -> URL {
        var p = path.hasPrefix("/") ? path : "/" + path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
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

    func get(_ path: String, _ q: [String: String] = [:], done: @escaping (Result<Any, APIError>) -> Void) {
        token(refresh: false) { [weak self] t in
            guard let s = self else { return }
            guard let t = t else { done(.failure(.offline("Couldn't reach Reddit. Pull down to try again.\n\n" + Reddit.diag))); return }
            s.call(path, q, token: t, refresh: true, done: done)
        }
    }

    /// Gets the guest token ready at launch, so the first feed doesn't wait for it.
    func prepare() { token(refresh: false) { _ in } }

    private func call(_ path: String, _ q: [String: String], token: String, refresh: Bool, done: @escaping (Result<Any, APIError>) -> Void) {
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
            if (code == 401 || code == 403), refresh {
                self.token(refresh: true) { fresh in
                    if let fresh = fresh, fresh != token { self.call(path, q, token: fresh, refresh: false, done: done) }
                    else { DispatchQueue.main.async { done(.failure(.http(code))) } }
                }
                return
            }
            let r: Result<Any, APIError>
            if code == 404 { r = .failure(.http(404)) }
            else if !(200 ..< 300).contains(code) { r = .failure(.http(code)) }
            else if let d = data, let j = try? JSONSerialization.jsonObject(with: d) { r = .success(j) }
            else { r = .failure(.bad) }
            DispatchQueue.main.async { done(r) }
        }.resume()
    }

    // MARK: the guest token — a plain HTTP request (no browser, no JavaScript), so iOS 15 handles it.
    // This is Reddit's documented "installed_client" grant for logged-out apps: it returns a bearer
    // token that reads all public content. Nothing personal, nothing stored, no account.

    /// Reddit's mobile-site app id (public, no secret); used only to ask for a logged-out token.
    private static let clientID = "ohXpoqrZYub1kg"
    static var diag = ""
    private var cached: String?
    private var until = Date.distantPast
    private var loading = false
    private var waiting: [(String?) -> Void] = []

    private func token(refresh: Bool, done: @escaping (String?) -> Void) {
        if !refresh, let t = cached, until > Date().addingTimeInterval(60) { done(t); return }
        waiting.append(done)
        guard !loading else { return }
        loading = true
        let finish: (String?, TimeInterval) -> Void = { [weak self] t, secs in
            guard let s = self else { return }
            s.cached = t
            s.until = Date().addingTimeInterval(secs)
            s.loading = false
            let w = s.waiting; s.waiting = []
            w.forEach { $0(t) }
        }
        // signed in: use your account token (Reddit serves content to it); else a logged-out guest token
        if isSignedIn {
            userToken { t in if let t = t { finish(t, 3600) } else { self.mintGuest(finish) } }
        } else {
            mintGuest(finish)
        }
    }

    /// Your account's bearer token, left in the app by the sign-in page (the `token_v2` cookie).
    private func userToken(_ done: @escaping (String?) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let t = cookies.first { $0.name == "token_v2" && $0.domain.hasSuffix("reddit.com") }?.value
            DispatchQueue.main.async { done((t?.isEmpty == false) ? t : nil) }
        }
    }

    private func mintGuest(_ done: @escaping (String?, TimeInterval) -> Void) {
        var req = URLRequest(url: URL(string: "https://www.reddit.com/api/v1/access_token")!)
        req.httpMethod = "POST"
        req.setValue("Basic " + Data("\(Reddit.clientID):".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(appUA, forHTTPHeaderField: "User-Agent")
        req.httpBody = Data("grant_type=https%3A%2F%2Foauth.reddit.com%2Fgrants%2Finstalled_client&device_id=DO_NOT_TRACK_THIS_DEVICE".utf8)
        session.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var tok: String?
            var secs: TimeInterval = 3600
            if let d = data, let j = try? JSONSerialization.jsonObject(with: d) as? JSON {
                tok = j["access_token"] as? String
                secs = (j["expires_in"] as? NSNumber)?.doubleValue ?? 3600
            }
            if tok == nil {
                let body = data.flatMap { String(data: $0.prefix(120), encoding: .utf8) } ?? ""
                Reddit.diag = "guest token: http=\(code) \(body.replacingOccurrences(of: "\n", with: " "))"
            }
            DispatchQueue.main.async { done(tok, secs) }
        }.resume()
    }

    // MARK: signing in (optional — unlocks the feeds Reddit won't serve to a logged-out app)

    var isSignedIn: Bool { UserDefaults.standard.bool(forKey: "signedIn") }

    func signedIn(_ yes: Bool) {
        UserDefaults.standard.set(yes, forKey: "signedIn")
        cached = nil
        NotificationCenter.default.post(name: Reddit.signedIn, object: nil)
    }

    func signOut() {
        cached = nil
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
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
