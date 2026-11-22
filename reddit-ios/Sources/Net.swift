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
        case .http(let c) where c == 401 || c == 403: return "Reddit won't show this (\(c)).\n\n" + Reddit.diag
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
        // Comment PAGES are confirmed: oauth refuses them for this app, old.reddit serves them with
        // your cookies — so go straight there (no wasted call, keeps them as quick as they are).
        if isSignedIn, Reddit.isCommentPage(path) {
            viaOldReddit(path, q, done: done)
            return
        }
        // Everything else (feeds, /new, /search, the comment API) asks oauth first with your account
        // token; call() falls back to old.reddit only if oauth refuses.
        oauthGet(path, q, done: done)
    }

    /// A single post's comment page (…/comments/<id>…) — the one thing old.reddit serves but oauth won't.
    static func isCommentPage(_ path: String) -> Bool {
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        if p.hasSuffix(".json") { p.removeLast(5) }
        return p.contains("/comments/") || p.hasPrefix("comments/")
    }

    private func oauthGet(_ path: String, _ q: [String: String], done: @escaping (Result<Any, APIError>) -> Void) {
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
            if resp as? HTTPURLResponse != nil { Reddit.lastOAuthCode = code }
            if (resp as? HTTPURLResponse) == nil, let err = err {
                DispatchQueue.main.async { done(.failure(.offline((err as NSError).code == NSURLErrorNotConnectedToInternet ? "No internet connection." : err.localizedDescription))) }
                return
            }
            if (code == 401 || code == 403), refresh {
                // oauth restricts /new and comment pages; read those the way your browser does —
                // old.reddit.com's .json with your login cookies (which Reddit serves fully).
                if self.isSignedIn {
                    self.viaOldReddit(path, q) { r2 in
                        if case .success = r2 { DispatchQueue.main.async { done(r2) } }
                        else { self.retryWithFreshToken(path, q, token: token, code: code, done: done) }
                    }
                } else {
                    self.retryWithFreshToken(path, q, token: token, code: code, done: done)
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

    private func retryWithFreshToken(_ path: String, _ q: [String: String], token old: String, code: Int, done: @escaping (Result<Any, APIError>) -> Void) {
        token(refresh: true) { fresh in
            if let fresh = fresh, fresh != old { self.call(path, q, token: fresh, refresh: false, done: done) }
            else { DispatchQueue.main.async { done(.failure(.http(code))) } }
        }
    }

    /// Fetches old.reddit.com/<path>.json with your login cookies — the same request your Safari
    /// makes, so Reddit serves the feeds (New) and comment pages it refuses over the API.
    private func viaOldReddit(_ path: String, _ q: [String: String], done: @escaping (Result<Any, APIError>) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let header = cookies.filter { $0.domain.hasSuffix("reddit.com") }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            var p = path.hasPrefix("/") ? path : "/" + path
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            if p.hasSuffix(".json") { p.removeLast(5) }
            var c = URLComponents()
            c.scheme = "https"; c.host = "old.reddit.com"; c.path = (p.isEmpty ? "/" : p) + ".json"
            c.queryItems = [URLQueryItem(name: "raw_json", value: "1")] + q.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let u = c.url else { DispatchQueue.main.async { done(.failure(.bad)) }; return }
            var req = URLRequest(url: u)
            req.setValue(safariUA, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if !header.isEmpty { req.setValue(header, forHTTPHeaderField: "Cookie") }
            let hasSession = cookies.contains { $0.name == "reddit_session" && $0.domain.hasSuffix("reddit.com") }
            self.session.dataTask(with: req) { data, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let r: Result<Any, APIError>
                if (200 ..< 300).contains(code), let d = data, let j = try? JSONSerialization.jsonObject(with: d) { r = .success(j) }
                else {
                    Reddit.diag = "token=\(Reddit.tokenKind) \(Reddit.mintInfo) oauth=\(Reddit.lastOAuthCode) · old.reddit \(c.path) http=\(code) session=\(hasSession ? "yes" : "no")"
                    r = .failure(.offline("Reddit won't show this.\n\n" + Reddit.diag))
                }
                DispatchQueue.main.async { done(r) }
            }.resume()
        }
    }

    // MARK: the guest token — a plain HTTP request (no browser, no JavaScript), so iOS 15 handles it.
    // This is Reddit's documented "installed_client" grant for logged-out apps: it returns a bearer
    // token that reads all public content. Nothing personal, nothing stored, no account.

    /// Reddit's mobile-site app id (public, no secret); used only to ask for a logged-out token.
    private static let clientID = "ohXpoqrZYub1kg"
    static var diag = ""
    /// Breadcrumbs for the diagnostic line: which token we're on, and what oauth last answered.
    static var tokenKind = "?"
    static var lastOAuthCode = 0
    static var mintInfo = "mint=?"
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
            userToken { t in
                if let t = t { Reddit.tokenKind = "account"; finish(t, 3600) }
                else { Reddit.tokenKind = "guest(mint-failed)"; self.mintGuest(finish) }
            }
        } else {
            Reddit.tokenKind = "guest"
            mintGuest(finish)
        }
    }

    /// Your account's bearer token from the sign-in: the `token_v2` cookie if present, otherwise
    /// minted from your login cookies (the way Reddit's own site turns a session into a token).
    private func userToken(_ done: @escaping (String?) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let mine = cookies.filter { $0.domain.hasSuffix("reddit.com") }
            if let t = mine.first(where: { $0.name == "token_v2" })?.value, !t.isEmpty {
                Reddit.mintInfo = "mint=cookie"
                DispatchQueue.main.async { done(t) }
                return
            }
            // no token_v2 (old.reddit login sets reddit_session): exchange the cookies for a token
            guard mine.contains(where: { $0.name == "reddit_session" }) else {
                Reddit.mintInfo = "mint=no-session(cookies:\(mine.map { $0.name }.joined(separator: ",")))"
                DispatchQueue.main.async { done(nil) }
                return
            }
            let header = mine.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            var req = URLRequest(url: URL(string: "https://accounts.reddit.com/api/access_token")!)
            req.httpMethod = "POST"
            req.setValue("Basic " + Data("\(Reddit.clientID):".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            req.setValue(header, forHTTPHeaderField: "Cookie")
            req.setValue(appUA, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["scopes": ["*"]])
            self.session.dataTask(with: req) { data, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let t = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? JSON)?["access_token"] as? String
                if let t = t, !t.isEmpty {
                    Reddit.mintInfo = "mint=\(code)ok"
                    DispatchQueue.main.async { done(t) }
                } else {
                    let body = data.flatMap { String(data: $0.prefix(50), encoding: .utf8) } ?? ""
                    Reddit.mintInfo = "mint=\(code) " + body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                    DispatchQueue.main.async { done(nil) }
                }
            }.resume()
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

    // MARK: joining subreddits (needs you signed in)

    /// Whether you already follow r/<name> (nil if unknown or not signed in), so the button reads right.
    func subStatus(_ name: String, done: @escaping (Bool?) -> Void) {
        guard isSignedIn else { done(nil); return }
        get("/r/\(name)/about") { r in
            if case .success(let j) = r { done((j as? JSON)?.o("data").b("user_is_subscriber")) }
            else { done(nil) }
        }
    }

    /// Follow or unfollow r/<name>, the way the site does it: your login cookies plus the page's modhash.
    func subscribe(_ name: String, join: Bool, done: @escaping (Bool) -> Void) {
        guard isSignedIn else { DispatchQueue.main.async { done(false) }; return }
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let header = cookies.filter { $0.domain.hasSuffix("reddit.com") }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            guard !header.isEmpty else { DispatchQueue.main.async { done(false) }; return }
            var me = URLRequest(url: URL(string: "https://old.reddit.com/api/me.json?raw_json=1")!)
            me.setValue(safariUA, forHTTPHeaderField: "User-Agent")
            me.setValue(header, forHTTPHeaderField: "Cookie")
            me.setValue("application/json", forHTTPHeaderField: "Accept")
            self.session.dataTask(with: me) { data, _, _ in
                let modhash = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? JSON)?.o("data").s("modhash") ?? ""
                guard !modhash.isEmpty else { DispatchQueue.main.async { done(false) }; return }
                var req = URLRequest(url: URL(string: "https://old.reddit.com/api/subscribe")!)
                req.httpMethod = "POST"
                req.setValue(safariUA, forHTTPHeaderField: "User-Agent")
                req.setValue(header, forHTTPHeaderField: "Cookie")
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                let sr = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
                req.httpBody = Data("action=\(join ? "sub" : "unsub")&sr_name=\(sr)&uh=\(modhash)&api_type=json&skip_initial_defaults=true".utf8)
                self.session.dataTask(with: req) { _, resp, _ in
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    DispatchQueue.main.async { done((200 ..< 300).contains(code)) }
                }.resume()
            }.resume()
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
