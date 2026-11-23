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
        if isSignedIn {
            // Comment pages and subreddit search: old.reddit's own .json serves these to the app with
            // your cookies, so go straight there (quick, already proven to work).
            if Reddit.isCommentPage(path) || Reddit.isSubredditSearch(path) {
                viaOldReddit(path, q, done: done)
                return
            }
            // New, post search and "load more comments": refused to the app on every plain request,
            // but your logged-in browser sees them — so read old.reddit's .json through a real web
            // view that carries your session and clears the bot-check. No oauth fallback: oauth 403s
            // these too, and falling back would just hide the web view's real result.
            if Reddit.needsWeb(path) {
                WebReddit.shared.get(path, q, done: done)
                return
            }
        }
        // Everything else (feeds) asks oauth with your token; call() falls back to old.reddit if refused.
        oauthGet(path, q, done: done)
    }

    /// A single post's comment page (…/comments/<id>…) — the one thing old.reddit serves but oauth won't.
    static func isCommentPage(_ path: String) -> Bool {
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        if p.hasSuffix(".json") { p.removeLast(5) }
        return p.contains("/comments/") || p.hasPrefix("comments/")
    }

    /// Subreddit search — old.reddit serves this to the app already, so it doesn't need the web view.
    static func isSubredditSearch(_ path: String) -> Bool {
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        if p.hasSuffix(".json") { p.removeLast(5) }
        return p == "subreddits/search"
    }

    /// New, post search, and the "load more comments" API — blocked on both oauth and old.reddit's
    /// plain .json, so these go through the logged-in web view (your real browser session) instead.
    static func needsWeb(_ path: String) -> Bool {
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        if p.hasSuffix(".json") { p.removeLast(5) }
        return p == "new" || p.hasSuffix("/new") || p == "search" || p.hasSuffix("/search")
            || p.hasPrefix("user/") || p.hasPrefix("message/")   // your posts/comments and your inbox
    }

    private func oauthGet(_ path: String, _ q: [String: String], done: @escaping (Result<Any, APIError>) -> Void) {
        token(refresh: false) { [weak self] t in
            guard let s = self else { return }
            guard let t = t else { done(.failure(.offline("Couldn't reach Reddit. Pull down to try again.\n\n" + Reddit.diag))); return }
            s.call(path, q, token: t, refresh: true, done: done)
        }
    }

    /// Gets the guest token ready at launch, so the first feed doesn't wait for it.
    func prepare() {
        token(refresh: false) { _ in }
        // warm the hidden web view in the background so New/search are ready the first time you tap them
        if isSignedIn { WebReddit.shared.warmup() }
    }

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
    private var cachedName: String?

    func signedIn(_ yes: Bool) {
        UserDefaults.standard.set(yes, forKey: "signedIn")
        cached = nil
        if !yes { cachedName = nil; UserDefaults.standard.removeObject(forKey: "myname") }
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
        WebReddit.shared.subStatus(name, done: done)
    }

    /// Who you're signed in as (cached once found), so the dashboard can load your posts and comments.
    func myName(done: @escaping (String?) -> Void) {
        if let n = cachedName, !n.isEmpty { done(n); return }
        if let n = UserDefaults.standard.string(forKey: "myname"), !n.isEmpty { cachedName = n; done(n); return }
        guard isSignedIn else { done(nil); return }
        WebReddit.shared.whoami { [weak self] name, _ in
            if let name = name, !name.isEmpty { self?.cachedName = name; UserDefaults.standard.set(name, forKey: "myname") }
            done(name)
        }
    }

    /// How many unread replies/messages you have, for the inbox dot (0 if signed out or unknown).
    /// Passive: it won't build the web view early — if it isn't warm yet, the dot just waits.
    func unread(done: @escaping (Int) -> Void) {
        guard isSignedIn, WebReddit.shared.isReady else { done(0); return }
        WebReddit.shared.whoami { [weak self] name, count in
            if let name = name, !name.isEmpty { self?.cachedName = name; UserDefaults.standard.set(name, forKey: "myname") }
            done(count)
        }
    }

    // MARK: writing — oauth.reddit.com with your account token (the route that still works in 2026;
    // old.reddit 403s writes, and the .json modhash read is blocked). `done` gets Reddit's own error
    // text, or nil on success. `confirm` checks the reply actually contains what proves it took.

    // `done` gets (errorText, responseJSON): error nil + the full reply on success, so a caller like
    // the comment screen can use what Reddit handed back instead of re-reading a slow/blocked endpoint.
    private func oauthWrite(_ path: String, _ fields: [String: String], confirm: @escaping (JSON) -> Bool, done: @escaping (String?, JSON?) -> Void) {
        token(refresh: false) { [weak self] t in
            guard let s = self, let t = t else { DispatchQueue.main.async { done("Couldn't get your Reddit token — open the menu and sign in again.", nil) }; return }
            s.writeCall(path, fields, token: t, confirm: confirm, retry: true, done: done)
        }
    }

    private func writeCall(_ path: String, _ fields: [String: String], token: String, confirm: @escaping (JSON) -> Bool, retry: Bool, done: @escaping (String?, JSON?) -> Void) {
        var c = URLComponents(); c.scheme = "https"; c.host = "oauth.reddit.com"; c.path = path
        guard let u = c.url else { DispatchQueue.main.async { done("Couldn't build the request.", nil) }; return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(appUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let ok = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var all = fields; all["api_type"] = "json"
        req.httpBody = all.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: ok) ?? "")" }.joined(separator: "&").data(using: .utf8)
        session.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let j = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? JSON
            // an expired token gives 401/403 with no Reddit error body — get a fresh one and try once more
            if (code == 401 || code == 403), retry, j == nil {
                self.token(refresh: true) { fresh in
                    if let fresh = fresh, fresh != token { self.writeCall(path, fields, token: fresh, confirm: confirm, retry: false, done: done) }
                    else { DispatchQueue.main.async { done("Reddit refused the write (\(code)).", nil) } }
                }
                return
            }
            DispatchQueue.main.async {
                if (resp as? HTTPURLResponse) == nil { done(err.map { ($0 as NSError).code == NSURLErrorNotConnectedToInternet ? "No internet connection." : $0.localizedDescription } ?? "Couldn't reach Reddit.", nil); return }
                if let errors = (j?["json"] as? JSON)?["errors"] as? [[Any]], let first = errors.first {
                    let msg = (first.count > 1 ? first[1] as? String : nil) ?? (first.first as? String) ?? "Reddit rejected it."
                    done(msg, nil); return
                }
                if !(200 ..< 300).contains(code) { done("Reddit refused the write (\(code)).", nil) ; return }
                if let j = j, confirm(j) { done(nil, j); return }
                done("Reddit accepted it but didn't confirm it — it may not have gone through.", nil)
            }
        }.resume()
    }

    /// Join/leave a subreddit (or follow/unfollow u_<name>). `done` gets Reddit's error text, or nil.
    func subscribe(_ name: String, join: Bool, done: @escaping (String?) -> Void) {
        guard isSignedIn else { DispatchQueue.main.async { done("Sign in first.") }; return }
        var fields = ["action": join ? "sub" : "unsub", "sr_name": name]
        if join { fields["skip_initial_defaults"] = "true" }   // valid only with sub — Reddit 400s if it's sent with unsub
        oauthWrite("/api/subscribe", fields, confirm: { _ in true }) { err, _ in done(err) }
    }

    /// Reply to a post or comment (its fullname). `done` gets an error (or nil) and, on success, the
    /// freshly created comment, so the screen can show it right away without re-reading the thread.
    func reply(to fullname: String, text: String, done: @escaping (String?, JSON?) -> Void) {
        guard isSignedIn else { DispatchQueue.main.async { done("Sign in first.", nil) }; return }
        oauthWrite("/api/comment", ["thing_id": fullname, "text": text],
                   confirm: { $0.o("json").o("data").a("things").count > 0 }) { err, j in
            done(err, j?.o("json").o("data").a("things").first?.o("data"))
        }
    }

    /// Submit a text post to r/<sr>. `done` gets an error message, or nil on success.
    func submit(sr: String, title: String, text: String, done: @escaping (String?) -> Void) {
        guard isSignedIn else { DispatchQueue.main.async { done("Sign in first.") }; return }
        oauthWrite("/api/submit", ["sr": sr, "kind": "self", "title": title, "text": text, "resubmit": "true", "sendreplies": "true"],
                   confirm: { let d = $0.o("json").o("data"); return !d.s("url").isEmpty || !d.s("name").isEmpty }) { err, _ in done(err) }
    }
}

// MARK: - reading through your browser session

/// A hidden, logged-in web view kept alive behind the app. Reddit refuses New, search and the
/// "load more comments" API to the app's own requests, but serves them to a real browser carrying
/// your session — so these go through here: it loads reddit.com (passing Reddit's bot/JS check the
/// way Safari does), then runs `fetch` for reddit.com's own .json from inside that page.
final class WebReddit: NSObject, WKNavigationDelegate {
    static let shared = WebReddit()
    private var web: WKWebView?
    private var ready = false
    private var creating = false
    private var pending: [() -> Void] = []

    // Block the heavy stuff the web view would otherwise render — we only need the page's HTML and the
    // bot-check script, never its images/fonts/styles. This keeps its WebContent process tiny so iOS
    // doesn't kill it on an older iPhone. (Our fetches get the raw HTML regardless of this.)
    private static let blockRules = """
    [{"trigger":{"url-filter":".*","resource-type":["image","media","font","style-sheet"]},"action":{"type":"block"}}]
    """

    private func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? UIApplication.shared.windows.first
    }

    /// Whether the web view is up and past the bot-check — so a passive check (the inbox dot) can use
    /// it without forcing it to build early and fight the first feed for memory on an older phone.
    var isReady: Bool { ready && web != nil }

    /// Start loading the web view ahead of time (called at launch), so the first New/search is instant.
    func warmup() {
        // a few seconds after launch (so the first feed loads smoothly first), then load in the background
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.ensure() }
    }

    private func ensure() {
        guard web == nil, !creating else { return }
        creating = true
        // compile the "block media" rules, then build the web view with them (keeps its process light).
        // If the rule store isn't available, build without them rather than never building at all.
        guard let store = WKContentRuleListStore.default() else { build(nil); return }
        store.compileContentRuleList(forIdentifier: "yrs-light", encodedContentRuleList: WebReddit.blockRules) { [weak self] list, _ in
            self?.build(list)
        }
    }

    private func build(_ rules: WKContentRuleList?) {
        creating = false
        guard web == nil else { return }
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()                 // the same cookie jar your sign-in used
        c.applicationNameForUserAgent = safariSuffix
        if let rules = rules { c.userContentController.add(rules) }
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: c)
        w.navigationDelegate = self
        w.isUserInteractionEnabled = false
        w.alpha = 0.01
        keyWindow()?.addSubview(w)                      // attached to the window so iOS keeps it running
        keyWindow()?.sendSubviewToBack(w)
        web = w
        // a tiny subreddit, with images/styles blocked, so the page is cheap to hold open
        w.load(URLRequest(url: URL(string: "https://old.reddit.com/r/test/")!))
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in self?.markReady() }
    }

    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
        // the page finished (bot-check cleared) — start serving almost immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.markReady() }
    }

    /// If iOS kills the web view's content process (memory pressure on an older phone), rebuild it so
    /// New/search/join keep working instead of silently dying.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        webView.removeFromSuperview()
        web = nil
        creating = false
        ensure()
    }

    private func markReady() {
        guard !ready, web != nil else { return }
        ready = true
        let p = pending; pending = []
        p.forEach { $0() }
    }

    /// Run `work` once the web view has loaded and cleared the bot-check (now, or when it's ready).
    private func whenReady(_ work: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.ensure()
            if self.ready { work() } else { self.pending.append(work) }
        }
    }

    func get(_ path: String, _ q: [String: String], done: @escaping (Result<Any, APIError>) -> Void) {
        whenReady { self.doFetch(path, q, attempt: 0, done: done) }
    }

    /// Whether you follow r/<name>, read through the browser session (about.json inside the page).
    func subStatus(_ name: String, done: @escaping (Bool?) -> Void) {
        whenReady {
            guard let web = self.web else { done(nil); return }
            let js = """
            try {
              const a = await (await fetch('https://old.reddit.com/r/' + encodeURIComponent(NAME) + '/about.json', {credentials:'include'})).json();
              return (a && a.data && a.data.user_is_subscriber) ? 'YES' : 'NO';
            } catch(e) { return '?'; }
            """
            web.callAsyncJavaScript(js, arguments: ["NAME": name], in: nil, in: .page) { res in
                DispatchQueue.main.async {
                    if case .success(let v) = res, let s = v as? String {
                        done(s == "YES" ? true : (s == "NO" ? false : nil))
                    } else { done(nil) }
                }
            }
        }
    }

    // Writes (subscribe / comment / submit) do NOT go through here — old.reddit 403s them. They run on
    // oauth.reddit.com with the account token (Reddit.oauthWrite), which is the route that still works.

    private func doFetch(_ path: String, _ q: [String: String], attempt: Int, done: @escaping (Result<Any, APIError>) -> Void) {
        guard let web = web else { done(.failure(.offline("Reddit won't show this. (web view not ready)"))); return }
        var p = path.hasPrefix("/") ? path : "/" + path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        if p.hasSuffix(".json") { p.removeLast(5) }
        // pick the reader for this kind of page: your inbox, a person's comments, or a list of posts
        let scraper: String
        if p.hasPrefix("/message/") { scraper = WebReddit.inboxJS }
        else if p.hasSuffix("/comments") { scraper = WebReddit.commentJS }
        else { scraper = WebReddit.scrapeJS }
        // the HTML page (NOT .json) — Reddit still serves this to a real browser, and old.reddit
        // renders ~25 posts right in the markup, where /new.json gets the 403 block page.
        var c = URLComponents()
        c.scheme = "https"; c.host = "old.reddit.com"; c.path = p.isEmpty ? "/" : p
        var items: [URLQueryItem] = []
        for (k, v) in q.sorted(by: { $0.key < $1.key }) where k != "raw_json" && k != "limit" {
            items.append(URLQueryItem(name: k, value: v))
        }
        if !items.isEmpty { c.queryItems = items }
        guard let u = c.url else { done(.failure(.bad)); return }
        web.callAsyncJavaScript(scraper, arguments: ["u": u.absoluteString], in: nil, in: .page) { res in
            DispatchQueue.main.async {
                var out = ""
                if case .success(let v) = res, let s = v as? String { out = s }
                if out.hasPrefix("{"), let d = out.data(using: .utf8),
                   let j = try? JSONSerialization.jsonObject(with: d) as? JSON {
                    let kids = j.o("data").a("children").count
                    let dg = j["_diag"] as? JSON ?? [:]
                    if kids > 0 { done(.success(j)); return }
                    // zero rows that read fine and aren't blocked = a genuinely empty page (no comments
                    // yet, empty inbox): hand it back as empty. Only blocked/half-loaded is an error.
                    if !dg.b("blocked"), dg.i("len") > 2000 { done(.success(j)); return }
                    if attempt > 0 {
                        Reddit.diag = "web old.reddit\(c.path): 0 rows things=\(dg.i("things")) blocked=\(dg.b("blocked")) len=\(dg.i("len"))"
                        done(.failure(.offline("Reddit won't show this.\n\n" + Reddit.diag)))
                        return
                    }
                }
                if attempt == 0 {
                    // page's bot-check may still be settling, or it was mid-load — wait and retry once
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.doFetch(path, q, attempt: 1, done: done) }
                } else {
                    Reddit.diag = "web old.reddit\(c.path): \(out.prefix(70).replacingOccurrences(of: "\n", with: " "))"
                    done(.failure(.offline("Reddit won't show this.\n\n" + Reddit.diag)))
                }
            }
        }
    }

    /// Runs in the logged-in web view: fetch old.reddit's HTML listing/search page and lift the posts
    /// out of its DOM into the same {data:{children:[t3…]}} shape the .json used to return.
    static let scrapeJS = """
    try {
      const r = await fetch(u, {credentials:'include', headers:{'Accept':'text/html'}});
      const html = await r.text();
      const doc = new DOMParser().parseFromString(html, 'text/html');
      const num = s => { const n = parseInt((s||'').replace(/[^0-9]/g,'')); return isNaN(n) ? 0 : n; };
      let children = [];
      const things = [].slice.call(doc.querySelectorAll('#siteTable .thing.link'));
      for (const t of things) {
        const d = t.dataset;
        if (!d.fullname || d.fullname.indexOf('t3_') !== 0) continue;
        const a = t.querySelector('a.title');
        const img = t.querySelector('.thumbnail img');
        let thumb = img ? img.getAttribute('src') : '';
        if (thumb && thumb.indexOf('//') === 0) thumb = 'https:' + thumb;
        if (thumb && thumb.indexOf('http') !== 0) thumb = '';
        children.push({kind:'t3', data:{
          id: d.fullname.slice(3), name: d.fullname,
          title: a ? a.textContent.trim() : '',
          url: d.url || (a ? a.getAttribute('href') : '') || '',
          permalink: d.permalink || '',
          author: d.author || '',
          subreddit: d.subreddit || '',
          domain: d.domain || '',
          score: num(d.score),
          num_comments: num(d.commentsCount),
          created_utc: (parseInt(d.timestamp) || 0) / 1000,
          over_18: d.nsfw === 'true',
          is_self: (d.domain || '').indexOf('self.') === 0,
          stickied: t.classList.contains('stickied'),
          thumbnail: thumb || ''
        }});
      }
      if (children.length === 0) {
        const srs = [].slice.call(doc.querySelectorAll('.search-result-link'));
        for (const el of srs) {
          const a = el.querySelector('a.search-title') || el.querySelector('header a') || el.querySelector('a.search-link');
          const meta = (el.querySelector('.search-result-meta') || {textContent:''}).textContent || '';
          const sub = el.querySelector('.search-subreddit-link');
          const au = el.querySelector('.author');
          const com = el.querySelector('.search-comments');
          let perma = com ? com.getAttribute('href') : (a ? a.getAttribute('href') : '');
          if (perma && perma.indexOf('http') === 0) { try { perma = new URL(perma).pathname; } catch(e) {} }
          const toks = meta.split(' ');
          let score = 0, ncom = 0;
          for (let i = 0; i < toks.length; i++) {
            if (toks[i].indexOf('point') === 0 && i > 0) score = num(toks[i-1]);
            if (toks[i].indexOf('comment') === 0 && i > 0) ncom = num(toks[i-1]);
          }
          const simg = el.querySelector('.thumbnail img') || el.querySelector('img');
          let sthumb = simg ? simg.getAttribute('src') : '';
          if (sthumb && sthumb.indexOf('//') === 0) sthumb = 'https:' + sthumb;
          if (sthumb && sthumb.indexOf('http') !== 0) sthumb = '';
          const sdomain = el.querySelector('.search-result-meta a.domain') || el.querySelector('span.domain');
          children.push({kind:'t3', data:{
            id:'', name:'',
            title: a ? a.textContent.trim() : '',
            url: (a ? a.getAttribute('href') : '') || '',
            permalink: perma || '',
            author: au ? au.textContent.trim() : '',
            subreddit: sub ? sub.textContent.replace('/r/','').replace('r/','') : '',
            domain: sdomain ? sdomain.textContent.trim() : '',
            score: score, num_comments: ncom, created_utc: 0,
            over_18:false, is_self:false, stickied:false, thumbnail: sthumb || ''
          }});
        }
      }
      let after = null;
      const nb = doc.querySelector('.next-button a');
      if (nb) { try { after = new URL(nb.href).searchParams.get('after'); } catch(e) {} }
      const blocked = html.indexOf('blocked by network security') >= 0 || html.indexOf('whoa there') >= 0;
      return JSON.stringify({kind:'Listing', data:{children: children, after: after}, _diag:{len: html.length, things: things.length, blocked: blocked}});
    } catch(e) { return 'ERR:' + e; }
    """

    /// Your username and unread count, read from your logged-in old.reddit homepage.
    func whoami(done: @escaping (String?, Int) -> Void) {
        whenReady {
            guard let web = self.web else { done(nil, 0); return }
            let js = """
            try {
              const r = await fetch('https://old.reddit.com/', {credentials:'include', headers:{'Accept':'text/html'}});
              const html = await r.text();
              const doc = new DOMParser().parseFromString(html, 'text/html');
              const a = doc.querySelector('#header-bottom-right .user a');
              let name = a ? a.textContent.trim() : '';
              if (!name || name.toLowerCase() === 'login') {
                let k = '"logged": "'; let i = html.indexOf(k);
                if (i < 0) { k = '"logged":"'; i = html.indexOf(k); }
                if (i >= 0) { const j = html.indexOf('"', i + k.length); if (j > i) name = html.slice(i + k.length, j); }
              }
              const mail = doc.querySelector('#mail');
              const have = mail ? mail.classList.contains('havemail') : false;
              const mc = doc.querySelector('#mail-count');
              let count = mc ? (parseInt((mc.textContent||'').replace(/[^0-9]/g,'')) || 0) : 0;
              if (!count && have) count = 1;
              return JSON.stringify({name: name, count: count});
            } catch(e) { return ''; }
            """
            web.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { res in
                DispatchQueue.main.async {
                    if case .success(let v) = res, let s = v as? String, let d = s.data(using: .utf8),
                       let j = (try? JSONSerialization.jsonObject(with: d)) as? JSON {
                        let name = j.s("name")
                        done(name.isEmpty ? nil : name, j.i("count"))
                    } else { done(nil, 0) }
                }
            }
        }
    }

    /// Lifts your comments out of old.reddit's /user/<you>/comments HTML (that .json is blocked).
    static let commentJS = """
    try {
      const r = await fetch(u, {credentials:'include', headers:{'Accept':'text/html'}});
      const html = await r.text();
      const doc = new DOMParser().parseFromString(html, 'text/html');
      const num = s => { const n = parseInt((s||'').replace(/[^0-9]/g,'')); return isNaN(n) ? 0 : n; };
      let children = [];
      const things = [].slice.call(doc.querySelectorAll('.thing.comment'));
      for (const t of things) {
        const d = t.dataset;
        if (!d.fullname || d.fullname.indexOf('t1_') !== 0) continue;
        const md = t.querySelector('.usertext-body .md') || t.querySelector('.md');
        const sc = t.querySelector('.score.unvoted');
        const time = t.querySelector('time');
        let ts = 0; if (time) { const dt = time.getAttribute('datetime'); if (dt) ts = Date.parse(dt) / 1000; }
        const by = t.querySelector('a.bylink');
        children.push({kind:'t1', data:{
          id: d.fullname.slice(3), name: d.fullname,
          author: d.author || '', subreddit: d.subreddit || '',
          body: md ? md.textContent.trim() : '',
          permalink: d.permalink || (by ? by.getAttribute('href') : '') || '',
          score: d.score ? num(d.score) : (sc ? num(sc.getAttribute('title') || sc.textContent) : 0),
          created_utc: ts || ((parseInt(d.timestamp) || 0) / 1000)
        }});
      }
      let after = null;
      const nb = doc.querySelector('.next-button a');
      if (nb) { try { after = new URL(nb.href).searchParams.get('after'); } catch(e) {} }
      const blocked = html.indexOf('blocked by network security') >= 0 || html.indexOf('whoa there') >= 0;
      return JSON.stringify({kind:'Listing', data:{children: children, after: after}, _diag:{len: html.length, things: things.length, blocked: blocked}});
    } catch(e) { return 'ERR:' + e; }
    """

    /// Lifts your inbox — replies to you and messages — out of old.reddit's /message HTML.
    static let inboxJS = """
    try {
      const r = await fetch(u, {credentials:'include', headers:{'Accept':'text/html'}});
      const html = await r.text();
      const doc = new DOMParser().parseFromString(html, 'text/html');
      let children = [];
      const things = [].slice.call(doc.querySelectorAll('#siteTable .thing.message, .thing.message'));
      for (const t of things) {
        const d = t.dataset;
        const au = t.querySelector('.sender a.author') || t.querySelector('a.author');
        const subj = t.querySelector('.subject');
        const md = t.querySelector('.md');
        const time = t.querySelector('time');
        let ts = 0; if (time) { const dt = time.getAttribute('datetime'); if (dt) ts = Date.parse(dt) / 1000; }
        let ctx = '';
        const cl = t.querySelector('a.context') || t.querySelector('.subject a[href*="/comments/"]');
        if (cl) { ctx = cl.getAttribute('href') || ''; if (ctx.indexOf('http') === 0) { try { ctx = new URL(ctx).pathname; } catch(e) {} } }
        let sub = d.subreddit || '';
        if (!sub && ctx) { const parts = ctx.split('/'); for (let i = 0; i < parts.length - 1; i++) { if (parts[i] === 'r') { sub = parts[i + 1]; break; } } }
        children.push({kind:'message', data:{
          author: au ? au.textContent.trim() : (d.author || ''),
          subject: subj ? subj.textContent.trim() : '',
          body: md ? md.textContent.trim() : '',
          context: ctx, subreddit: sub,
          was_comment: !!cl || t.classList.contains('comment'),
          new: t.classList.contains('new'),
          created_utc: ts
        }});
      }
      const blocked = html.indexOf('blocked by network security') >= 0 || html.indexOf('whoa there') >= 0;
      return JSON.stringify({kind:'Listing', data:{children: children, after: null}, _diag:{len: html.length, things: things.length, blocked: blocked}});
    } catch(e) { return 'ERR:' + e; }
    """
}

// MARK: - pictures

enum Images {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 8_000_000   // a few screens' worth, then the oldest go
        return c
    }()

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 4
        c.httpAdditionalHeaders = ["User-Agent": safariUA, "Accept": "image/jpeg,image/png,image/*;q=0.8"]
        return URLSession(configuration: c)
    }()

    /// The one thing that keeps scrolling smooth on an A9: decode only a couple of pictures at a time
    /// (decoding is the heavy part), instead of letting every visible cell decode at once.
    private static let work: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    /// On-disk copy of the shrunk pictures, so they don't download or re-decode next time.
    private static let diskDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("yrs-img", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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

    private static func diskURL(_ k: String) -> URL {
        var h: UInt64 = 14695981039346656037          // FNV-1a — a stable name for this key
        for b in k.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return diskDir.appendingPathComponent(String(h, radix: 16) + ".img")
    }

    private static func remember(_ img: UIImage, _ k: String) {
        cache.setObject(img, forKey: k as NSString, cost: Int(img.size.width * img.size.height * img.scale * img.scale * 4))
    }

    private static func get(_ u: URL, key: String, make: @escaping (Data) -> UIImage?, done: @escaping (UIImage?) -> Void) -> URLSessionDataTask? {
        let k = key + u.absoluteString
        if let i = cache.object(forKey: k as NSString) { done(i); return nil }   // in memory already
        let file = diskURL(k)
        // the download; only resumed if the picture isn't already on disk
        let task = session.dataTask(with: u) { data, _, _ in
            guard let data = data else { DispatchQueue.main.async { done(nil) }; return }
            work.addOperation {   // bounded — at most 2 decodes run at once
                let img = autoreleasepool { make(data) }
                if let img = img {
                    remember(img, k)
                    try? img.jpegData(compressionQuality: 0.85)?.write(to: file, options: .atomic)
                }
                DispatchQueue.main.async { done(img) }
            }
        }
        // check the disk first (also bounded); fall through to the download only on a miss
        work.addOperation {
            if let d = try? Data(contentsOf: file), let img = UIImage(data: d) {
                remember(img, k)
                DispatchQueue.main.async { done(img) }
            } else {
                task.resume()
            }
        }
        return task
    }

    /// Keep the on-disk cache from growing forever: drop the oldest files past a size cap.
    static func trimDisk() {
        work.addOperation {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
            guard let files = try? fm.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: keys) else { return }
            var items = files.map { url -> (URL, Date, Int) in
                let v = try? url.resourceValues(forKeys: Set(keys))
                return (url, v?.contentModificationDate ?? .distantPast, v?.totalFileAllocatedSize ?? 0)
            }
            var total = items.reduce(0) { $0 + $1.2 }
            let cap = 60_000_000
            guard total > cap else { return }
            items.sort { $0.1 < $1.1 }   // oldest first
            for (url, _, size) in items where total > cap {
                try? fm.removeItem(at: url)
                total -= size
            }
        }
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
