// Reading Pinterest the way its own website does, and pictures fetched at the size they're shown,
// with only a few screens' worth kept. Signed in, it also reads your own home feed; your Pinterest
// login (the session cookie) stays in this app on your iPhone and is never saved or sent anywhere else.

import ImageIO
import UIKit
import WebKit

enum APIError: Error, CustomStringConvertible {
    case http(Int)
    case offline(String)
    case bad

    var description: String {
        switch self {
        case .http(404): return "Not found."
        case .http(429): return "Pinterest says too many requests. Wait a minute and pull down to try again."
        case .http(let c): return "Pinterest answered \(c). Pull down to try again."
        case .offline(let m): return m
        case .bad: return "Pinterest sent something unexpected. Pull down to try again."
        }
    }
}

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func s(_ k: String) -> String { self[k] as? String ?? "" }
    func i(_ k: String) -> Int { (self[k] as? NSNumber)?.intValue ?? 0 }
    func o(_ k: String) -> JSON { self[k] as? JSON ?? [:] }
    func a(_ k: String) -> [JSON] { self[k] as? [JSON] ?? [] }
}

enum Style {
    static let text = UIColor(white: 0.92, alpha: 1)
    static let dim = UIColor(white: 0.52, alpha: 1)
    static let faint = UIColor(white: 0.14, alpha: 1)
    static let card = UIColor(white: 0.10, alpha: 1)
    /// The one warm accent (Pinterest red), used only for primary actions.
    static let accent = UIColor(red: 0.90, green: 0.12, blue: 0.22, alpha: 1)
    static let link = UIColor(white: 0.92, alpha: 1)
}

/// What Safari on this iPhone calls itself.
let safariUA: String = {
    let v = UIDevice.current.systemVersion
    let major = v.split(separator: ".").first.map(String.init) ?? "15"
    return "Mozilla/5.0 (iPhone; CPU iPhone OS \(v.replacingOccurrences(of: ".", with: "_")) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).0 Mobile/15E148 Safari/604.1"
}()

/// A pin, from a search or a person's pins.
struct Pin {
    let j: JSON
    var id: String { j.s("id") }
    var title: String {
        let t = j.s("grid_title").isEmpty ? j.s("title") : j.s("grid_title")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var about: String { j.s("description").trimmingCharacters(in: .whitespacesAndNewlines) }
    var user: String { j.o("pinner").s("username") }
    var userName: String { j.o("pinner").s("full_name") }
    var board: String { j.o("board").s("name") }
    var link: URL? { URL(string: j.s("link")) }
    var page: URL? { URL(string: "https://www.pinterest.com/pin/\(id)/") }
    var color: UIColor {
        let h = j.s("dominant_color").replacingOccurrences(of: "#", with: "")
        guard h.count == 6, let v = Int(h, radix: 16) else { return UIColor(white: 0.12, alpha: 1) }
        // darkened, so it's a quiet placeholder while the picture loads
        return UIColor(red: CGFloat(v >> 16 & 255) / 600, green: CGFloat(v >> 8 & 255) / 600, blue: CGFloat(v & 255) / 600, alpha: 1)
    }

    /// One of Pinterest's sizes ("236x", "474x", "736x", "orig") from an images dict, with h/w.
    static func pick(_ imgs: JSON, _ size: String) -> (URL, CGFloat)? {
        for k in [size, "474x", "736x", "236x", "orig"] {
            let im = imgs.o(k)
            if let u = URL(string: im.s("url")), im.i("width") > 0 {
                return (u, CGFloat(im.i("height")) / CGFloat(im.i("width")))
            }
        }
        return nil
    }

    /// The pin's (cover) picture at the given size.
    func image(_ size: String) -> (URL, CGFloat)? { Pin.pick(j.o("images"), size) }

    /// A multi-photo "carousel" pin's slides (more than one means it's swipeable).
    var slides: [JSON] { j.o("carousel_data").a("carousel_slots") }
    var isGallery: Bool { slides.count > 1 }

    /// Every full-size picture to view: each carousel slide, or just the one cover.
    func allImages(_ size: String = "orig") -> [URL] {
        if isGallery {
            let urls = slides.compactMap { Pin.pick($0.o("images"), size)?.0 }
            if !urls.isEmpty { return urls }
        }
        return (image("736x")?.0 ?? gridImage("736x")?.0).map { [$0] } ?? []
    }

    /// Plays a video pin, and the video pages/blocks of an idea pin. HLS first, then MP4 variants.
    var video: URL? {
        if let u = Pin.pickVideo(j.o("videos").o("video_list")) { return u }
        for page in j.o("story_pin_data").a("pages") {
            if let u = Pin.pickVideo(page.o("video").o("video_list")) { return u }
            for block in page.a("blocks") { if let u = Pin.pickVideo(block.o("video").o("video_list")) { return u } }
        }
        return nil
    }

    /// The best directly-downloadable MP4 for saving to Photos — never the HLS playlist, never the
    /// cover. Pinterest caps video at 720p, so V_720P is the target; otherwise the widest .mp4.
    var videoFile: URL? {
        if let u = Pin.bestMP4(j.o("videos").o("video_list")) { return u }
        for page in j.o("story_pin_data").a("pages") {
            if let u = Pin.bestMP4(page.o("video").o("video_list")) { return u }
            for block in page.a("blocks") { if let u = Pin.bestMP4(block.o("video").o("video_list")) { return u } }
        }
        return nil
    }

    /// From a video_list: the clean 720p progressive MP4 (V_720P), else the widest .mp4 — and never an
    /// HLS (.m3u8) entry, which can't be saved to Photos as a plain file.
    private static func bestMP4(_ list: JSON) -> URL? {
        var cands: [(url: URL, width: Int, is720: Bool)] = []
        for (key, v) in list {
            guard let d = v as? JSON else { continue }
            let s = d.s("url"), k = key.uppercased()
            guard !s.isEmpty, !k.contains("HLS"), !s.hasSuffix(".m3u8"), s.contains(".mp4"), let u = URL(string: s) else { continue }
            cands.append((u, d.i("width"), k == "V_720P"))
        }
        if let p = cands.first(where: { $0.is720 }) { return p.url }
        return cands.max { $0.width < $1.width }?.url
    }

    /// The HLS (.m3u8) master playlist — used only when there's no direct MP4, to assemble one.
    var hlsURL: URL? {
        func hls(_ list: JSON) -> URL? {
            for k in ["V_HLSV4", "V_HLSV3_MOBILE", "V_HLSV3_WEB"] {
                let s = list.o(k).s("url")
                if !s.isEmpty, s.contains(".m3u8"), let u = URL(string: s) { return u }
            }
            for (_, v) in list { if let d = v as? JSON { let s = d.s("url"); if s.contains(".m3u8"), let u = URL(string: s) { return u } } }
            return nil
        }
        if let u = hls(j.o("videos").o("video_list")) { return u }
        for page in j.o("story_pin_data").a("pages") {
            if let u = hls(page.o("video").o("video_list")) { return u }
            for block in page.a("blocks") { if let u = hls(block.o("video").o("video_list")) { return u } }
        }
        return nil
    }

    /// Whether this is a video (for the ▶ badge in the grid), checked without building a URL.
    var isVideo: Bool {
        if !j.o("videos").o("video_list").isEmpty { return true }
        for page in j.o("story_pin_data").a("pages") {
            if !page.o("video").o("video_list").isEmpty { return true }
            for block in page.a("blocks") where !block.o("video").o("video_list").isEmpty { return true }
        }
        return false
    }

    private static func pickVideo(_ list: JSON) -> URL? {
        for k in ["V_HLSV4", "V_HLSV3_MOBILE", "V_HLSV3_WEB", "V_720P", "V_EXP7", "V_EXP6", "V_EXP5", "V_EXP4", "V_480P", "V_240P"] {
            let s = list.o(k).s("url")
            if !s.isEmpty, let u = URL(string: s) { return u }
        }
        for (_, v) in list { if let d = v as? JSON, !d.s("url").isEmpty, let u = URL(string: d.s("url")) { return u } }
        return nil
    }

    /// The grid/cover picture, falling back to an idea pin's first-page image when the pin carries no
    /// top-level images dict — so video and idea pins show a cover instead of being dropped or blank.
    func gridImage(_ size: String) -> (URL, CGFloat)? {
        if let r = image(size) { return r }
        if let page = j.o("story_pin_data").a("pages").first {
            if let r = Pin.pick(page.o("image").o("images"), size) { return r }
            if let r = Pin.pick(page.o("images"), size) { return r }
        }
        return nil
    }

    /// A promoted pin — i.e. an ad. Pinterest slips these into the feed shaped like ordinary pins
    /// (that Audi, that villa); only ad objects carry these fields, so organic pins are never dropped.
    var isAd: Bool {
        if (j["is_promoted"] as? NSNumber)?.boolValue == true { return true }
        if (j["promoted_is_removable"] as? NSNumber)?.boolValue == true { return true }
        if let s = j["ad_destination_url"] as? String, !s.isEmpty { return true }
        if let p = j["promoter"] as? JSON, !p.isEmpty { return true }
        if let s = j["ad_group_id"] as? String, !s.isEmpty { return true }
        return false
    }

    /// Picture URLs to try when saving, best quality first: Pinterest's listed "orig", the biggest
    /// listed size upgraded to the full-resolution /originals/ path, then that size itself.
    var saveCandidates: [URL] {
        let imgs = j.o("images")
        var urls: [String] = []
        if !imgs.o("orig").s("url").isEmpty { urls.append(imgs.o("orig").s("url")) }
        let sized = ["736x", "600x", "564x", "474x", "236x", "170x"].compactMap { k -> (String, Int)? in
            let im = imgs.o(k); let s = im.s("url"); return s.isEmpty ? nil : (s, im.i("width"))
        }.sorted { $0.1 > $1.1 }
        if let biggest = sized.first?.0 {
            if let orig = Pin.originalize(biggest) { urls.append(orig) }
            urls.append(biggest)
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0).inserted }.compactMap { URL(string: $0) }
    }

    /// Rewrites an i.pinimg.com thumbnail URL (…/736x/…) to its full-resolution original (…/originals/…).
    static func originalize(_ url: String) -> String? {
        guard url.contains("i.pinimg.com"), let r = url.range(of: #"/\d+x/"#, options: .regularExpression) else { return nil }
        return url.replacingCharacters(in: r, with: "/originals/")
    }
}

/// One of your boards.
struct Board {
    let j: JSON
    var id: String { j.s("id") }
    var name: String { j.s("name") }
    var pinCount: Int { (j["pin_count"] as? NSNumber)?.intValue ?? 0 }
    var isSecret: Bool { (j["privacy"] as? String) == "secret" }
    /// The board's cover picture, trying the shapes Pinterest uses across board objects.
    var cover: URL? {
        for key in ["image_cover_hd_url", "image_cover_url"] {
            if let s = j[key] as? String, let u = URL(string: s), !s.isEmpty { return u }
        }
        let covers = j.o("cover_images")
        for k in ["474x", "236x", "736x", "216x", "200x"] {
            if let u = URL(string: covers.o(k).s("url")), !covers.o(k).s("url").isEmpty { return u }
        }
        if let first = (j["cover_pin"] as? JSON).flatMap({ Pin.pick($0.o("images"), "236x") }) { return first.0 }
        return Pin.pick(j.o("images"), "236x")?.0
    }
}

/// Your Pinterest login. The session cookie lives only in this app's own cookie store on the
/// iPhone (where the sign-in page put it); it is attached to requests and never written to a file,
/// a log, or sent anywhere but Pinterest.
enum Account {
    static let changed = Notification.Name("yrs.pins.account")
    private static let store = WKWebsiteDataStore.default()
    private static var appVersion: String?
    private static var cachedUsername: String?

    static var isSignedIn: Bool { UserDefaults.standard.bool(forKey: "signedIn") }

    /// Looks at the cookies the sign-in page left, and remembers whether you're signed in.
    static func refresh(_ done: @escaping (Bool) -> Void = { _ in }) {
        store.httpCookieStore.getAllCookies { cookies in
            let auth = cookies.first { $0.name == "_auth" && $0.domain.contains("pinterest") }
            let yes = (auth?.value ?? "0") != "0" && !(auth?.value ?? "").isEmpty
            let was = UserDefaults.standard.bool(forKey: "signedIn")
            UserDefaults.standard.set(yes, forKey: "signedIn")
            if was != yes { NotificationCenter.default.post(name: Account.changed, object: nil) }
            done(yes)
        }
    }

    static func signOut() {
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let pin = records.filter { $0.displayName.contains("pinterest") }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: pin) {
                UserDefaults.standard.set(false, forKey: "signedIn")
                cachedUsername = nil
                UserDefaults.standard.removeObject(forKey: "username")
                NotificationCenter.default.post(name: Account.changed, object: nil)
            }
        }
    }

    /// Cookie header, the CSRF token, and the site version, gathered for a signed-in request.
    static func auth(_ done: @escaping (_ cookie: String, _ csrf: String, _ version: String?) -> Void) {
        store.httpCookieStore.getAllCookies { cookies in
            let mine = cookies.filter { $0.domain.contains("pinterest") }
            let header = mine.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            let csrf = mine.first { $0.name == "csrftoken" }?.value ?? ""
            if let v = appVersion { done(header, csrf, v); return }
            version { done(header, csrf, $0) }
        }
    }

    /// The site's current build id, read once from the home page (a header Pinterest expects).
    private static func version(_ done: @escaping (String?) -> Void) {
        var req = URLRequest(url: URL(string: "https://www.pinterest.com/")!)
        req.setValue(safariUA, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { d, _, _ in
            let html = d.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if let r = html.range(of: "\"app_version\":\"") {
                let rest = html[r.upperBound...]
                let v = String(rest.prefix { $0.isHexDigit })
                if v.count >= 5 { appVersion = v }
            }
            DispatchQueue.main.async { done(appVersion) }
        }.resume()
    }

    /// Your username, needed for your boards and profile. Pinterest has no "who am I" endpoint, so we
    /// read it once from your logged-in home page (where the viewer's own account fields appear) and cache it.
    static func whoami(_ done: @escaping (String?) -> Void) {
        if let u = cachedUsername, !u.isEmpty { done(u); return }
        if let u = UserDefaults.standard.string(forKey: "username"), !u.isEmpty { cachedUsername = u; done(u); return }
        guard isSignedIn else { done(nil); return }
        auth { cookie, _, _ in
            var req = URLRequest(url: URL(string: "https://www.pinterest.com/")!)
            req.setValue(safariUA, forHTTPHeaderField: "User-Agent")
            if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
            URLSession.shared.dataTask(with: req) { d, _, _ in
                let html = d.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let name = parseUsername(html)
                if let name = name { cachedUsername = name; UserDefaults.standard.set(name, forKey: "username") }
                DispatchQueue.main.async { done(name) }
            }.resume()
        }
    }

    /// Finds the logged-in user's username in the home HTML: a "username" sitting next to an
    /// account-only field (email / has_password / login_state) that only the viewer object carries.
    private static func parseUsername(_ html: String) -> String? {
        for m in ["\"has_password\"", "\"is_email_verified\"", "\"login_state\"", "\"email\""] {
            var from = html.startIndex
            while let mr = html.range(of: m, range: from ..< html.endIndex) {
                let lo = html.index(mr.lowerBound, offsetBy: -1400, limitedBy: html.startIndex) ?? html.startIndex
                let hi = html.index(mr.upperBound, offsetBy: 1400, limitedBy: html.endIndex) ?? html.endIndex
                if let u = firstString(String(html[lo ..< hi]), key: "username"), u.count >= 3, u.count <= 40 { return u }
                from = mr.upperBound
            }
        }
        return nil
    }

    private static func firstString(_ s: String, key: String) -> String? {
        guard let r = s.range(of: "\"\(key)\":\"") ?? s.range(of: "\"\(key)\": \"") else { return nil }
        let v = String(s[r.upperBound...].prefix { $0 != "\"" })
        return v.isEmpty ? nil : v
    }
}

enum Pinterest {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.httpMaximumConnectionsPerHost = 2
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    /// One of the website's own requests. When signed in, your login cookies are attached so
    /// Pinterest answers as it does in your browser. Replies on the main queue with the data and
    /// the bookmark for the next page (nil at the end).
    static func get(_ resource: String, source: String, handler: String, options: JSON, auth: Bool = false, done: @escaping (Result<(Any?, String?), APIError>) -> Void) {
        let body: JSON = ["options": options, "context": [:] as JSON]
        guard let data = try? JSONSerialization.data(withJSONObject: body), let ds = String(data: data, encoding: .utf8) else { done(.failure(.bad)); return }
        var c = URLComponents(string: "https://www.pinterest.com/resource/\(resource)/get/")!
        c.queryItems = [URLQueryItem(name: "source_url", value: source), URLQueryItem(name: "data", value: ds)]
        guard let u = c.url else { done(.failure(.bad)); return }
        var req = URLRequest(url: u)
        req.setValue(safariUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("www/\(handler).js", forHTTPHeaderField: "X-Pinterest-PWS-Handler")
        req.setValue(source, forHTTPHeaderField: "X-Pinterest-Source-Url")

        let fire = { (self.session).dataTask(with: req) { d, resp, err in
            let r: Result<(Any?, String?), APIError>
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let err = err {
                r = .failure(.offline((err as NSError).code == NSURLErrorNotConnectedToInternet ? "No internet connection." : err.localizedDescription))
            } else if code == 403, auth {
                r = .failure(.offline("Pinterest didn't accept the sign-in. Try signing in again."))
            } else if !(200 ..< 300).contains(code) {
                r = .failure(.http(code))
            } else if let j = d.flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? JSON {
                let rr = j.o("resource_response")
                // the next-page bookmark sits on resource_response, or on resource.options.bookmarks
                var bm = rr.s("bookmark")
                if bm.isEmpty { bm = (j.o("resource").o("options")["bookmarks"] as? [Any])?.first as? String ?? "" }
                r = .success((rr["data"], bm.isEmpty || bm == "-end-" ? nil : bm))
            } else {
                r = .failure(.bad)
            }
            DispatchQueue.main.async { done(r) }
        }.resume() }

        if auth {
            Account.auth { cookie, csrf, version in
                if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
                if !csrf.isEmpty { req.setValue(csrf, forHTTPHeaderField: "X-CSRFToken") }
                if let v = version { req.setValue(v, forHTTPHeaderField: "X-APP-VERSION") }
                req.setValue("1", forHTTPHeaderField: "X-Requested-With")
                fire()
            }
        } else {
            fire()
        }
    }

    /// Pins in a search or a list reply, including the ones grouped inside "stories".
    static func pins(_ data: Any?) -> [Pin] {
        let list: [JSON] = (data as? [JSON]) ?? ((data as? JSON)?.a("results") ?? [])
        var out: [Pin] = []
        var seen = Set<String>()
        func add(_ x: JSON) {
            switch x.s("type") {
            case "pin": out.append(Pin(j: x))
            case "story": x.a("objects").forEach(add)                   // a story module groups pins
            default:
                if x["images"] != nil { out.append(Pin(j: x)) }        // a pin with no explicit type
                else { x.a("objects").forEach(add) }                   // a related-pins module wraps them in objects
            }
        }
        list.forEach(add)
        // keep anything with a cover (images, or an idea/video pin's fallback); drop ads and duplicates
        return out.filter { p in
            p.gridImage("236x") != nil && !p.isAd && seen.insert(p.id.isEmpty ? UUID().uuidString : p.id).inserted
        }
    }

    /// A POST to one of the website's `create` endpoints (saving a pin, making a board). Needs sign-in.
    static func post(_ resource: String, source: String, options: JSON, done: @escaping (Result<Any?, APIError>) -> Void) {
        let body: JSON = ["options": options, "context": [:] as JSON]
        guard let data = try? JSONSerialization.data(withJSONObject: body), let ds = String(data: data, encoding: .utf8),
              let u = URL(string: "https://www.pinterest.com/resource/\(resource)/create/") else { done(.failure(.bad)); return }
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "source_url", value: source), URLQueryItem(name: "data", value: ds)]
        let bodyData = (form.percentEncodedQuery ?? "").data(using: .utf8)
        Account.auth { cookie, csrf, version in
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.httpBody = bodyData
            req.setValue(safariUA, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            req.setValue("https://www.pinterest.com/", forHTTPHeaderField: "Referer")
            req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
            if !csrf.isEmpty { req.setValue(csrf, forHTTPHeaderField: "X-CSRFToken") }
            if let v = version { req.setValue(v, forHTTPHeaderField: "X-APP-VERSION") }
            session.dataTask(with: req) { d, resp, err in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let r: Result<Any?, APIError>
                if let err = err {
                    r = .failure(.offline((err as NSError).code == NSURLErrorNotConnectedToInternet ? "No internet connection." : err.localizedDescription))
                } else if code == 401 || code == 403 {
                    r = .failure(.offline("Pinterest didn't accept it — try signing in again."))
                } else if !(200 ..< 300).contains(code) {
                    r = .failure(.http(code))
                } else if let j = (d.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? JSON {
                    let rr = j.o("resource_response")
                    if let e = rr["error"] as? JSON, !e.isEmpty {
                        r = .failure(.offline(e.s("message").isEmpty ? "Pinterest wouldn't do that." : e.s("message")))
                    } else if rr.s("status") == "error" || rr.s("status") == "failure" {
                        r = .failure(.offline("Pinterest wouldn't do that."))
                    } else {
                        r = .success(rr["data"])
                    }
                } else {
                    r = .failure(.bad)
                }
                DispatchQueue.main.async { done(r) }
            }.resume()
        }
    }

    /// Your own home feed (needs sign-in).
    static func home(bookmark: String?, done: @escaping (Result<([Pin], String?), APIError>) -> Void) {
        var o: JSON = ["field_set_key": "hf_grid", "in_nux": false, "prependPartner": false, "static_feed": false]
        if let b = bookmark { o["bookmarks"] = [b] }
        get("UserHomefeedResource", source: "/", handler: "index", options: o, auth: true) { r in
            done(r.map { (pins($0.0), $0.1) })
        }
    }

    static func search(_ q: String, bookmark: String?, done: @escaping (Result<([Pin], String?), APIError>) -> Void) {
        var o: JSON = ["query": q, "scope": "pins", "page_size": 25]
        if let b = bookmark { o["bookmarks"] = [b] }
        get("BaseSearchResource", source: "/search/pins/?q=" + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q), handler: "search/[scope]", options: o, auth: Account.isSignedIn) { r in
            done(r.map { (pins($0.0), $0.1) })
        }
    }

    static func user(_ name: String, bookmark: String?, done: @escaping (Result<([Pin], String?), APIError>) -> Void) {
        var o: JSON = ["username": name, "field_set_key": "grid_item"]
        if let b = bookmark { o["bookmarks"] = [b] }
        get("UserActivityPinsResource", source: "/\(name)/_created/", handler: "[username]/_created", options: o, auth: Account.isSignedIn) { r in
            done(r.map { (pins($0.0), $0.1) })
        }
    }

    /// "More like this" — Pinterest's own related feed for a pin (the real recommendations, not a
    /// text search). Works off the pin's id; the caller falls back to a search if this comes back empty.
    static func related(pinID: String, bookmark: String?, done: @escaping (Result<([Pin], String?), APIError>) -> Void) {
        guard !pinID.isEmpty else { done(.success(([], nil))); return }
        var o: JSON = ["pin_id": pinID, "page_size": 25, "add_vase": true, "pins_only": false]
        if let b = bookmark { o["bookmarks"] = [b] }
        get("RelatedModulesResource", source: "/pin/\(pinID)/", handler: "PinCloseup", options: o, auth: Account.isSignedIn) { r in
            done(r.map { (pins($0.0), $0.1) })
        }
    }

    /// Your boards (needs sign-in). Resolves your username first, then asks for the board list.
    static func boards(bookmark: String?, done: @escaping (Result<([Board], String?), APIError>) -> Void) {
        Account.whoami { name in
            guard let name = name, !name.isEmpty else {
                done(.failure(.offline("Couldn't find your Pinterest profile. Pull down to retry, or sign in again."))); return
            }
            var o: JSON = ["username": name, "field_set_key": "profile_grid_item", "privacy_filter": "all",
                           "sort": "custom", "page_size": 50, "include_archived": true]
            if let b = bookmark { o["bookmarks"] = [b] }
            get("BoardsResource", source: "/\(name)/boards/", handler: "[username]/boards", options: o, auth: true) { r in
                done(r.map { d in ((d.0 as? [JSON] ?? []).filter { !$0.s("name").isEmpty }.map { Board(j: $0) }, d.1) })
            }
        }
    }

    /// The pins in one of your boards.
    static func boardFeed(boardID: String, bookmark: String?, done: @escaping (Result<([Pin], String?), APIError>) -> Void) {
        var o: JSON = ["board_id": boardID, "field_set_key": "react_grid_pin", "filter_section_pins": true, "page_size": 25]
        if let b = bookmark { o["bookmarks"] = [b] }
        get("BoardFeedResource", source: "/", handler: "[username]/[slug]", options: o, auth: true) { r in
            done(r.map { (pins($0.0), $0.1) })
        }
    }

    /// Your own pins (everything you've saved and created).
    static func myPins(bookmark: String?, done: @escaping (Result<([Pin], String?), APIError>) -> Void) {
        Account.whoami { name in
            guard let name = name, !name.isEmpty else {
                done(.failure(.offline("Couldn't find your Pinterest profile. Pull down to retry, or sign in again."))); return
            }
            var o: JSON = ["username": name, "field_set_key": "grid_item", "is_own_profile_pins": true, "page_size": 25]
            if let b = bookmark { o["bookmarks"] = [b] }
            get("UserPinsResource", source: "/\(name)/_saved/", handler: "[username]", options: o, auth: true) { r in
                done(r.map { (pins($0.0), $0.1) })
            }
        }
    }

    /// Save (repin) a pin onto one of your boards. Succeeds silently; `done(nil)` means it went through.
    static func save(pinID: String, boardID: String, done: @escaping (String?) -> Void) {
        guard !pinID.isEmpty, !boardID.isEmpty else { done("Missing the pin or board."); return }
        post("RepinResource", source: "/pin/\(pinID)/", options: ["pin_id": pinID, "board_id": boardID, "is_buyable_pin": false]) { r in
            switch r {
            case .success: done(nil)
            case .failure(let e): done(e.description)
            }
        }
    }
}

// MARK: - HLS video → MP4 (for streaming-only pins)

/// Turns a Pinterest HLS video into one playable MP4 on the phone — no re-encoding, no ffmpeg. Modern
/// HLS (CMAF/fMP4) is an init segment plus media fragments that concatenate byte-for-byte into a valid
/// MP4, so this is just: fetch the playlist, download the pieces, join them. Full, lossless quality.
/// An old MPEG-TS stream (no init segment) can't be assembled this way → caller shows a fallback.
enum HLSVideo {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpMaximumConnectionsPerHost = 6     // fetch segments in parallel for speed
        c.timeoutIntervalForRequest = 30
        c.httpAdditionalHeaders = ["User-Agent": safariUA]
        return URLSession(configuration: c)
    }()

    /// `progress` is 0…1 (on the main queue). `done` gets a local .mp4 file URL, or a short error code
    /// ("ts" = MPEG-TS, can't assemble; else a generic failure).
    static func assemble(_ master: URL, progress: @escaping (Double) -> Void, done: @escaping (URL?, String?) -> Void) {
        text(master) { t in
            guard let t = t else { fail("net", done); return }
            if t.contains("#EXT-X-STREAM-INF") {                 // a master playlist → pick the best variant
                guard let v = bestVariant(t, base: master) else { fail("net", done); return }
                text(v) { mt in
                    guard let mt = mt else { fail("net", done); return }
                    build(mt, base: v, progress: progress, done: done)
                }
            } else {
                build(t, base: master, progress: progress, done: done)
            }
        }
    }

    private static func fail(_ code: String, _ done: @escaping (URL?, String?) -> Void) {
        DispatchQueue.main.async { done(nil, code) }
    }

    private static func text(_ u: URL, done: @escaping (String?) -> Void) {
        session.dataTask(with: u) { d, _, _ in done(d.flatMap { String(data: $0, encoding: .utf8) }) }.resume()
    }

    /// The highest-resolution variant URI from a master playlist.
    private static func bestVariant(_ master: String, base: URL) -> URL? {
        let lines = master.components(separatedBy: .newlines)
        var best: (score: Int, url: URL)?
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                var score = 0
                if let r = line.range(of: "RESOLUTION=") {
                    let dims = line[r.upperBound...].prefix { $0 != "," && !$0.isWhitespace }.split(separator: "x")
                    if dims.count == 2, let w = Int(dims[0]), let h = Int(dims[1]) { score = w * h }
                }
                if score == 0, let r = line.range(of: "BANDWIDTH=") { score = Int(line[r.upperBound...].prefix { $0.isNumber }) ?? 0 }
                var j = i + 1
                while j < lines.count {
                    let uri = lines[j].trimmingCharacters(in: .whitespaces)
                    if !uri.isEmpty, !uri.hasPrefix("#") {
                        if let url = URL(string: uri, relativeTo: base)?.absoluteURL, best == nil || score > best!.score { best = (score, url) }
                        break
                    }
                    j += 1
                }
                i = j
            }
            i += 1
        }
        return best?.url
    }

    /// Parse a media playlist (init segment + fragments), download everything, and join in order.
    private static func build(_ media: String, base: URL, progress: @escaping (Double) -> Void, done: @escaping (URL?, String?) -> Void) {
        var initURL: URL?
        var segs: [URL] = []
        for raw in media.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MAP:"), let r = line.range(of: "URI=\"") {
                let uri = String(line[r.upperBound...].prefix { $0 != "\"" })
                initURL = URL(string: uri, relativeTo: base)?.absoluteURL
            } else if !line.isEmpty, !line.hasPrefix("#") {
                if let u = URL(string: line, relativeTo: base)?.absoluteURL { segs.append(u) }
            }
        }
        guard let initURL = initURL else { fail("ts", done); return }    // no init segment = MPEG-TS
        guard !segs.isEmpty else { fail("net", done); return }

        let all = [initURL] + segs
        var parts = [Data?](repeating: nil, count: all.count)
        var finished = 0
        var failed = false
        let lock = NSLock()
        let group = DispatchGroup()
        for (idx, u) in all.enumerated() {
            group.enter()
            session.dataTask(with: u) { d, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                lock.lock()
                if let d = d, !d.isEmpty, (200 ..< 300).contains(code) { parts[idx] = d } else { failed = true }
                finished += 1
                let frac = Double(finished) / Double(all.count)
                lock.unlock()
                DispatchQueue.main.async { progress(frac) }
                group.leave()
            }.resume()
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            if failed { fail("net", done); return }
            var full = Data()
            for p in parts { guard let p = p else { fail("net", done); return }; full.append(p) }
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("yrs-\(UUID().uuidString).mp4")
            do { try full.write(to: out) } catch { fail("save", done); return }
            DispatchQueue.main.async { done(out, nil) }
        }
    }
}

// MARK: - pictures

enum Images {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 4_000_000   // a few screens' worth of thumbnails, then the oldest go
        c.countLimit = 80
        return c
    }()

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 3
        c.httpMaximumConnectionsPerHost = 5
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

