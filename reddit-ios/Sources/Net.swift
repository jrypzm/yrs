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
/// web view, which passes Reddit's "real browser" check and leaves a `token_v2` cookie; that cookie
/// is used as the API key. Signed in, it's your token (your feeds work); signed out, it's a guest
/// token (public subreddits work). Nothing leaves your iPhone. This is light: the web view runs only
/// to get or refresh the token, then is let go of.
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

    var isSignedIn: Bool { UserDefaults.standard.bool(forKey: "signedIn") }

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
            guard let t = t else { done(.failure(.offline("Couldn't reach Reddit. Pull down to try again."))); return }
            s.call(path, q, token: t, retry: true) { r in
                // Reddit refuses the /new listing to app tokens; the same posts come through search, newest first
                if case .failure(.http(403)) = r, let (fp, fq) = Reddit.newViaSearch(path, q) {
                    s.call(fp, fq, token: t, retry: true, done: done)
                } else {
                    done(r)
                }
            }
        }
    }

    /// "/r/pics/new" → search r/pics sorted by new; the front page's "/new" → all of Reddit, newest.
    static func newViaSearch(_ path: String, _ q: [String: String]) -> (String, [String: String])? {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        guard p.hasSuffix("/new") else { return nil }
        var fq = q
        fq["sort"] = "new"
        fq["t"] = "all"
        fq["include_over_18"] = "on"
        let parts = p.split(separator: "/").map(String.init)
        if parts.count == 3, parts[0] == "r", !["all", "popular"].contains(parts[1].lowercased()) {
            fq["q"] = "subreddit:\(parts[1])"
            fq["restrict_sr"] = "1"
            return ("/r/\(parts[1])/search", fq)
        }
        fq["q"] = "self:yes OR self:no"
        return ("/search", fq)
    }

    private func call(_ path: String, _ q: [String: String], token: String, retry: Bool, done: @escaping (Result<Any, APIError>) -> Void) {
        var req = URLRequest(url: url(path, q))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(safariUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (resp as? HTTPURLResponse) == nil, let err = err {
                DispatchQueue.main.async { done(.failure(.offline((err as NSError).code == NSURLErrorNotConnectedToInternet ? "No internet connection." : err.localizedDescription))) }
                return
            }
            // a stale or guest token Reddit rejects: get a fresh token_v2 from the browser and try once more
            if (code == 401 || code == 403), retry {
                self.token(refresh: true) { fresh in
                    if let fresh = fresh, fresh != token { self.call(path, q, token: fresh, retry: false, done: done) }
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

    // MARK: the token (the reddit.com "token_v2" cookie, used as the API key)

    private var cached: String?
    private var loading = false
    private var waiting: [(String?) -> Void] = []

    /// The token_v2 value. `refresh` forces a new one from the browser (after Reddit rejects one).
    private func token(refresh: Bool, done: @escaping (String?) -> Void) {
        if !refresh, let t = cached { done(t); return }
        waiting.append(done)
        guard !loading else { return }
        loading = true
        let finish: (String?) -> Void = { [weak self] t in
            guard let s = self else { return }
            s.cached = t
            s.loading = false
            let w = s.waiting; s.waiting = []
            w.forEach { $0(t) }
        }
        if refresh { cached = nil; TokenWeb.clearCookie { self.fetchToken(finish) } }
        else { readCookie { t in if let t = t { finish(t) } else { self.fetchToken(finish) } } }
    }

    private func readCookie(_ done: @escaping (String?) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let t = cookies.first { $0.name == "token_v2" && $0.domain.hasSuffix("reddit.com") }?.value
            DispatchQueue.main.async { done((t?.isEmpty == false) ? t : nil) }
        }
    }

    /// Loads reddit.com in a hidden web view until a token_v2 cookie appears, then reads it.
    private func fetchToken(_ done: @escaping (String?) -> Void) {
        TokenWeb.warmUp { [weak self] in self?.readCookie(done) }
    }

    // MARK: signing in and out

    func signedIn(_ yes: Bool) {
        UserDefaults.standard.set(yes, forKey: "signedIn")
        cached = nil
        NotificationCenter.default.post(name: Reddit.signedIn, object: nil)
    }

    func signOut() {
        cached = nil
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            self?.signedIn(false)
        }
    }
}

/// A hidden web view used only to get or refresh the reddit.com token_v2 cookie, then let go of.
final class TokenWeb: NSObject, WKNavigationDelegate {
    private static var shared: TokenWeb?
    private var web: WKWebView?
    private var done: (() -> Void)?
    private var poll: Timer?
    private var tries = 0

    static func warmUp(_ done: @escaping () -> Void) {
        let t = TokenWeb()
        shared = t
        t.start(done)
    }

    static func clearCookie(_ done: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default()
        store.httpCookieStore.getAllCookies { cookies in
            let group = DispatchGroup()
            for c in cookies where c.name == "token_v2" && c.domain.hasSuffix("reddit.com") {
                group.enter(); store.httpCookieStore.delete(c) { group.leave() }
            }
            group.notify(queue: .main) { done() }
        }
    }

    private func start(_ done: @escaping () -> Void) {
        self.done = done
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()
        c.applicationNameForUserAgent = safariSuffix
        let v = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 400), configuration: c)
        v.navigationDelegate = self
        web = v
        v.load(URLRequest(url: URL(string: "https://www.reddit.com/")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25))
        // give up after 15 s whatever happens
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.stop() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { check() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { check() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { check() }

    /// After the page loads, poll briefly for the token_v2 cookie (the challenge may set it late).
    private func check() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            s.tries += 1
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let has = cookies.contains { $0.name == "token_v2" && $0.domain.hasSuffix("reddit.com") && !$0.value.isEmpty }
                if has || s.tries >= 20 { s.stop() }
            }
        }
    }

    private func stop() {
        poll?.invalidate(); poll = nil
        web?.navigationDelegate = nil
        web?.stopLoading()
        web = nil
        let d = done; done = nil
        TokenWeb.shared = nil
        DispatchQueue.main.async { malloc_zone_pressure_relief(nil, 0) }
        d?()
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
