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

    /// No login: the app only ever uses the guest token.
    var isSignedIn: Bool { false }

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
        // public reading (subreddits, search, new, profiles) goes through a guest token, which Reddit
        // serves fully; your own login is used only for your front page and your subs.
        let preferGuest = Reddit.isPublic(path) || !isSignedIn
        attempt(path, q, guest: preferGuest, triedGuest: preferGuest, done: done)
    }

    /// Public content any logged-out visitor can read (so the guest token works and isn't restricted).
    static func isPublic(_ path: String) -> Bool {
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        return p.hasPrefix("r/") || p.hasPrefix("user/") || p.hasPrefix("search")
            || p.hasPrefix("by_id") || p.hasPrefix("comments") || p.hasPrefix("subreddits/search")
    }

    private func attempt(_ path: String, _ q: [String: String], guest: Bool, triedGuest: Bool, done: @escaping (Result<Any, APIError>) -> Void) {
        token(guest: guest, refresh: false) { [weak self] t in
            guard let s = self else { return }
            guard let t = t else {
                if !guest { s.attempt(path, q, guest: true, triedGuest: true, done: done) }
                else { done(.failure(.offline("Couldn't reach Reddit. Pull down to try again.\n\n" + TokenWeb.diag))) }
                return
            }
            s.call(path, q, token: t, guest: guest, refresh: true) { r in
                // the logged-in token is more restricted than a guest one: on a refusal, try the guest token
                if case .failure(.http(403)) = r, !triedGuest {
                    s.attempt(path, q, guest: true, triedGuest: true, done: done)
                } else {
                    done(r)
                }
            }
        }
    }

    /// Gets both tokens ready at launch, so the first feed doesn't wait for them.
    func prepare() {
        // one time: drop any leftover login from older versions, so the token is truly a guest token
        if !UserDefaults.standard.bool(forKey: "wentGuest") {
            UserDefaults.standard.set(true, forKey: "wentGuest")
            let store = WKWebsiteDataStore.default()
            store.httpCookieStore.getAllCookies { cookies in
                let g = DispatchGroup()
                for c in cookies where c.domain.hasSuffix("reddit.com") { g.enter(); store.httpCookieStore.delete(c) { g.leave() } }
                g.notify(queue: .main) { self.guestSlot.value = nil; self.token(guest: true, refresh: false) { _ in } }
            }
        } else {
            token(guest: true, refresh: false) { _ in }
        }
    }

    private func call(_ path: String, _ q: [String: String], token: String, guest: Bool, refresh: Bool, done: @escaping (Result<Any, APIError>) -> Void) {
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
            // a lapsed token: get a fresh token_v2 of the same kind and try once more
            if (code == 401 || code == 403), refresh {
                self.token(guest: guest, refresh: true) { fresh in
                    if let fresh = fresh, fresh != token { self.call(path, q, token: fresh, guest: guest, refresh: false, done: done) }
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

    // MARK: the tokens (the reddit.com "token_v2" cookie, used as the API key)
    // Two of them: a guest token (from a logged-out browser session) for public reading, and your
    // signed-in token (from the browser you logged in with) for your own front page and subs.

    private final class Slot {
        var value: String?
        var loading = false
        var waiting: [(String?) -> Void] = []
    }
    private let guestSlot = Slot()
    private let userSlot = Slot()
    /// A browser session that never holds your login, so its token_v2 is a guest token.
    // the normal browser session; with no login it already holds only an anonymous (guest) token_v2
    static let guestStore = WKWebsiteDataStore.default()

    private func store(guest: Bool) -> WKWebsiteDataStore { guest ? Reddit.guestStore : WKWebsiteDataStore.default() }

    private func token(guest: Bool, refresh: Bool, done: @escaping (String?) -> Void) {
        let slot = guest ? guestSlot : userSlot
        if !refresh, let v = slot.value { done(v); return }
        slot.waiting.append(done)
        guard !slot.loading else { return }
        slot.loading = true
        let st = store(guest: guest)
        let finish: (String?) -> Void = { t in
            slot.value = t
            slot.loading = false
            let w = slot.waiting; slot.waiting = []
            w.forEach { $0(t) }
        }
        if refresh { slot.value = nil; TokenWeb.clearCookie(st) { self.fetchToken(st, finish) } }
        else { readCookie(st) { t in if let t = t { finish(t) } else { self.fetchToken(st, finish) } } }
    }

    private func readCookie(_ store: WKWebsiteDataStore, _ done: @escaping (String?) -> Void) {
        store.httpCookieStore.getAllCookies { cookies in
            let t = cookies.first { $0.name == "token_v2" && $0.domain.hasSuffix("reddit.com") }?.value
            DispatchQueue.main.async { done((t?.isEmpty == false) ? t : nil) }
        }
    }

    private func fetchToken(_ store: WKWebsiteDataStore, _ done: @escaping (String?) -> Void) {
        TokenWeb.warmUp(store) { [weak self] in self?.readCookie(store, done) }
    }

    // MARK: signing in and out

    func signedIn(_ yes: Bool) {
        UserDefaults.standard.set(yes, forKey: "signedIn")
        userSlot.value = nil
        NotificationCenter.default.post(name: Reddit.signedIn, object: nil)
    }

    func signOut() {
        userSlot.value = nil
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            self?.signedIn(false)
        }
    }
}

/// A hidden web view used only to get or refresh a reddit.com token_v2 cookie, then let go of.
/// It takes the data store to use: the shared one (your login) or the guest one (logged out).
final class TokenWeb: NSObject, WKNavigationDelegate {
    /// What the last token fetch saw, shown in the error so a failure is diagnosable from the phone.
    static var diag = ""
    private static var active: [TokenWeb] = []
    private var web: WKWebView?
    private var store: WKWebsiteDataStore!
    private var done: (() -> Void)?
    private var poll: Timer?
    private var tries = 0
    private var loaded = false
    private var status = 0
    private var failMsg = ""

    static func warmUp(_ store: WKWebsiteDataStore, _ done: @escaping () -> Void) {
        let t = TokenWeb()
        t.store = store
        active.append(t)
        t.start(done)
    }

    static func clearCookie(_ store: WKWebsiteDataStore, _ done: @escaping () -> Void) {
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
        c.websiteDataStore = store
        c.applicationNameForUserAgent = safariSuffix
        // full-screen behind the app, so iOS gives it full resources and runs Reddit's JS check
        let frame = UIApplication.shared.windows.first?.bounds ?? CGRect(x: 0, y: 0, width: 390, height: 700)
        let v = WKWebView(frame: frame, configuration: c)
        v.navigationDelegate = self
        v.isUserInteractionEnabled = false
        if let w = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) ?? UIApplication.shared.windows.first {
            w.insertSubview(v, at: 0)
        }
        web = v
        v.load(URLRequest(url: URL(string: "https://www.reddit.com/")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25))
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.stop() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame { status = (navigationResponse.response as? HTTPURLResponse)?.statusCode ?? 0 }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true; check() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failMsg = (error as NSError).localizedDescription; check() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failMsg = (error as NSError).localizedDescription; check() }

    private var reloaded = false
    private func check() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            s.tries += 1
            s.store.httpCookieStore.getAllCookies { cookies in
                let has = cookies.contains { $0.name == "token_v2" && $0.domain.hasSuffix("reddit.com") && !$0.value.isEmpty }
                if has || s.tries >= 46 { s.stop(); return }
                // Reddit's check sometimes needs a second visit: reload once around 7s in
                if !s.reloaded, s.tries == 14 {
                    s.reloaded = true
                    s.web?.load(URLRequest(url: URL(string: "https://www.reddit.com/")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25))
                }
            }
        }
    }

    private func stop() {
        poll?.invalidate(); poll = nil
        let url = web?.url?.host ?? "—"
        web?.navigationDelegate = nil
        web?.stopLoading()
        web?.removeFromSuperview()
        web = nil
        let d = done; done = nil
        TokenWeb.active.removeAll { $0 === self }
        store.httpCookieStore.getAllCookies { cookies in
            let mine = cookies.filter { $0.domain.hasSuffix("reddit.com") }
            let tok = mine.contains { $0.name == "token_v2" && !$0.value.isEmpty }
            let names = mine.map { $0.name }.sorted().joined(separator: ",")
            TokenWeb.diag = "token_v2=\(tok ? "YES" : "no") · loaded=\(self.loaded) http=\(self.status)\ncookies: \(names.isEmpty ? "none" : names)\(self.failMsg.isEmpty ? "" : " · \(self.failMsg)")"
            DispatchQueue.main.async { malloc_zone_pressure_relief(nil, 0); d?() }
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
