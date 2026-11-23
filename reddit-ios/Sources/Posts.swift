// Posts: what each one is (text, a picture, a gallery, a video, a link), its row in a list,
// and the lists themselves (a subreddit, the front page, a person's posts, search results).

import UIKit

struct Pic {
    let url: URL
    /// height / width
    let ratio: CGFloat
}

enum Media {
    case none
    case image(Pic, full: URL)
    case gallery([Pic], full: [URL])
    case video(URL, poster: Pic?)
}

struct Post {
    let j: JSON
    var id: String { j.s("id") }
    var title: String { j.s("title") }
    var sub: String { j.s("subreddit") }
    var author: String { j.s("author") }
    var permalink: String { j.s("permalink") }
    var link: String { j.s("url") }
    var isSelf: Bool { j.b("is_self") }
    var nsfw: Bool { j.b("over_18") }

    /// The picture to show at `px` pixels wide: the smallest of Reddit's sizes that's big enough.
    static func pick(_ image: JSON, px: CGFloat) -> Pic? {
        var all = image.a("resolutions")
        all.append(image.o("source"))
        let usable = all.filter { !$0.s("url").isEmpty && $0.i("width") > 0 }
        guard !usable.isEmpty else { return nil }
        let p = usable.first { CGFloat($0.i("width")) >= px } ?? usable.last!
        guard let u = URL(string: p.s("url")) else { return nil }
        return Pic(url: u, ratio: CGFloat(p.i("height")) / CGFloat(max(p.i("width"), 1)))
    }

    private var preview: JSON { (j.o("preview")["images"] as? [JSON])?.first ?? [:] }

    func thumb(px: CGFloat) -> URL? {
        if let p = Post.pick(preview, px: px) { return p.url }
        if let first = gallery(px: px).first { return first.url }
        let t = j.s("thumbnail")
        return t.hasPrefix("http") ? URL(string: t) : nil
    }

    private func gallery(px: CGFloat) -> [Pic] {
        let meta = j.o("media_metadata")
        return j.o("gallery_data").a("items").compactMap { item -> Pic? in
            let m = meta.o(item.s("media_id"))
            var sizes = m.a("p").map { ["url": $0.s("u"), "width": $0.i("x"), "height": $0.i("y")] as JSON }
            let s = m.o("s")
            sizes.append(["url": s.s("u").isEmpty ? s.s("gif") : s.s("u"), "width": s.i("x"), "height": s.i("y")])
            return Post.pick(["resolutions": Array(sizes.dropLast()), "source": sizes.last!], px: px)
        }
    }

    func media(px: CGFloat) -> Media {
        let poster = Post.pick(preview, px: px)
        for v in [j.o("secure_media").o("reddit_video"), j.o("media").o("reddit_video"), j.o("preview").o("reddit_video_preview")] {
            if let u = URL(string: v.s("hls_url")), !v.s("hls_url").isEmpty { return .video(u, poster: poster) }
        }
        let mp4 = preview.o("variants").o("mp4").o("source").s("url")
        if !mp4.isEmpty, let u = URL(string: mp4) { return .video(u, poster: poster) }
        if j.b("is_gallery") {
            let small = gallery(px: px), big = gallery(px: px * 1.6)
            if !small.isEmpty { return .gallery(small, full: big.map { $0.url }) }
        }
        let hint = j.s("post_hint")
        if hint == "image" || link.hasSuffix(".jpg") || link.hasSuffix(".png") || link.hasSuffix(".jpeg") || link.hasSuffix(".webp") {
            if let p = poster { return .image(p, full: Post.pick(preview, px: px * 1.6)?.url ?? p.url) }
        }
        return .none
    }

    var kind: String {
        switch media(px: 320) {
        case .video: return "video"
        case .gallery(let p, _): return "\(p.count) pictures"
        case .image: return "picture"
        case .none: return isSelf ? "" : (URL(string: link)?.host ?? "").replacingOccurrences(of: "www.", with: "")
        }
    }

    var item: Item {
        let p = self
        let meta = joined(["r/" + sub, "u/" + author, count(j.i("score")) + " points", count(j.i("num_comments")) + " comments", ago(j.d("created_utc"))])
        let tags = joined([j.b("stickied") ? "pinned" : "", nsfw ? "NSFW" : "", j.b("spoiler") ? "spoiler" : "", kind])
        return Item(title: title, detail: tags.isEmpty ? meta : meta + "\n" + tags, open: { PostVC(p) }, thumb: thumb(px: Cell.thumbSide * UIScreen.main.scale * 2))
    }
}

enum Make {
    /// A row for anything in a Reddit list.
    static func item(_ child: JSON) -> Item? {
        let d = child.o("data")
        switch child.s("kind") {
        case "t3": return Post(j: d).item
        case "t5":
            let name = d.s("display_name")
            let desc = d.s("public_description")
            let tags = joined([count(d.i("subscribers")) + " members", d.b("over18") ? "NSFW" : ""])
            return Item(title: "r/" + name, detail: desc.isEmpty ? tags : desc + "\n" + tags, open: { Lists.sub(name) })
        default: return nil
        }
    }

    /// A row for one of your own comments — tapping it opens the thread it's in.
    static func commentItem(_ child: JSON) -> Item? {
        guard child.s("kind") == "t1" else { return nil }
        let d = child.o("data")
        let body = d.s("body")
        let meta = joined(["r/" + d.s("subreddit"), count(d.i("score")) + " points", ago(d.d("created_utc"))])
        let perma = d.s("permalink")
        return Item(title: body.isEmpty ? "(comment)" : body, detail: meta,
                    open: { perma.isEmpty ? nil : PostVC(permalink: perma) })
    }

    /// A row for one inbox item — a reply opens its thread; a plain message opens its text.
    static func messageItem(_ child: JSON) -> Item? {
        let d = child.o("data")
        let author = d.s("author"), body = d.s("body"), sub = d.s("subreddit"), subject = d.s("subject")
        let where_ = d.b("was_comment") ? ("replied" + (sub.isEmpty ? "" : " in r/" + sub)) : "messaged you"
        let detail = joined([(d.b("new") ? "• " : "") + "u/" + (author.isEmpty ? "someone" : author), where_, ago(d.d("created_utc"))])
        var perma = d.s("context")
        if let q = perma.firstIndex(of: "?") { perma = String(perma[..<q]) }   // the thread loads; a context= tail would break it
        return Item(title: body.isEmpty ? (subject.isEmpty ? "(message)" : subject) : body, detail: detail,
                    open: {
                        if perma.isEmpty { return MessageVC(from: author, subject: subject, body: body) }
                        return PostVC(permalink: perma)
                    })
    }
}

/// Remembers where the next page starts.
private final class Cursor { var after: String? }

enum Lists {
    static let sorts = ["Hot", "New", "Top", "Rising"]

    /// A list of posts (or subreddits) at `path`, a page at a time.
    static func feed(_ title: String, choices: [String] = [], path: @escaping (Int) -> (String, [String: String])) -> Feed {
        let cur = Cursor()
        return Feed(title, choices: choices) { choice, page, done in
            if page == 1 { cur.after = nil }
            var (p, q) = path(choice)
            q["limit"] = "25"
            if let a = cur.after { q["after"] = a }
            Reddit.shared.get(p, q) { r in
                done(r.map { j in
                    let d = (j as? JSON)?.o("data") ?? [:]
                    cur.after = d["after"] as? String
                    return (d.a("children").compactMap(Make.item), cur.after != nil)
                })
            }
        }
    }

    static func sortPath(_ base: String, _ choice: Int) -> (String, [String: String]) {
        let s = sorts[min(choice, sorts.count - 1)].lowercased()
        return (base + "/" + s, s == "top" ? ["t": "day"] : [:])
    }

    /// Reddit's own "meta" feeds — not real subreddits, so no Join / post buttons on them.
    static func isMeta(_ name: String) -> Bool {
        ["popular", "all", "home", "front", "friends", "mod"].contains(name.lowercased())
    }

    static func sub(_ name: String) -> Feed {
        let f = feed("r/" + name, choices: sorts) { sortPath("/r/" + name, $0) }
        f.navigationItem.title = "r/" + name
        var items: [UIBarButtonItem] = [StarButton(name)]
        if Reddit.shared.isSignedIn, !Lists.isMeta(name) {
            items.insert(JoinButton(name), at: 0)       // Join on the subreddit page
            items.insert(ComposeButton(sub: name), at: 0)   // ＋ to post to this subreddit (rightmost)
        }
        f.navigationItem.rightBarButtonItems = items
        return f
    }

    static func front() -> Feed {
        feed("Front page", choices: ["Hot", "New", "Top", "Rising"]) { c in
            switch c {
            case 0: return ("/hot", [:])
            case 1: return ("/new", [:])
            case 2: return ("/top", ["t": "day"])
            default: return ("/rising", [:])
            }
        }
    }

    static func user(_ name: String) -> Feed {
        let f = feed("u/" + name, choices: ["New", "Top"]) { c in ("/user/\(name)/submitted", ["sort": c == 0 ? "new" : "top"]) }
        if Reddit.shared.isSignedIn { f.navigationItem.rightBarButtonItem = JoinButton(follow: name) }
        return f
    }

    static func search(_ q: String) -> Feed {
        // sort posts by relevance/hot/top/new, or switch to finding subreddits (Reddit search has no "rising")
        let tabs = ["Relevant", "Hot", "Top", "New", "Subs"]
        return feed(q, choices: tabs) { c in
            if c == 4 { return ("/subreddits/search", ["q": q]) }
            let sort = ["relevance", "hot", "top", "new"][c]
            var p = ["q": q, "sort": sort]
            if sort == "top" { p["t"] = "all" }
            return ("/search", p)
        }
    }

    /// Your dashboard: your posts, your comments, and your inbox (who replied). Needs you signed in.
    /// Each tab reads through the logged-in browser session, the same route New and search use.
    static func me(tab: Int = 0) -> Feed {
        let cur = Cursor()
        let f = Feed("Me", choices: ["Posts", "Comments", "Inbox"]) { choice, page, done in
            if page == 1 { cur.after = nil }
            Reddit.shared.myName { name in
                guard let name = name, !name.isEmpty else {
                    done(.failure(.offline("Couldn't tell who you're signed in as. Open the menu and sign in again."))); return
                }
                var q: [String: String] = ["limit": "25"]
                if let a = cur.after { q["after"] = a }
                let path: String
                switch choice {
                case 1: path = "/user/\(name)/comments"
                case 2: path = "/message/inbox"
                default: path = "/user/\(name)/submitted"
                }
                Reddit.shared.get(path, q) { r in
                    done(r.map { j in
                        let d = (j as? JSON)?.o("data") ?? [:]
                        cur.after = d["after"] as? String
                        let rows: [Item] = d.a("children").compactMap { c in
                            switch choice {
                            case 1: return Make.commentItem(c)
                            case 2: return Make.messageItem(c)
                            default: return Make.item(c)
                            }
                        }
                        return (rows, cur.after != nil)
                    })
                }
            }
        }
        f.select(tab)
        return f
    }
}

enum Favorites {
    static var all: [String] { UserDefaults.standard.stringArray(forKey: "favorites") ?? [] }
    static func has(_ s: String) -> Bool { all.contains { $0.lowercased() == s.lowercased() } }
    static func toggle(_ s: String) {
        var a = all
        if has(s) { a.removeAll { $0.lowercased() == s.lowercased() } } else { a.append(s) }
        a.sort { $0.lowercased() < $1.lowercased() }
        UserDefaults.standard.set(a, forKey: "favorites")
    }
}

/// Remembers what you've joined/followed in the app, so the button stays right across launches — the
/// real "are you subscribed?" check (about.json) is one of the endpoints Reddit now blocks.
enum Joined {
    static func has(_ s: String) -> Bool { (UserDefaults.standard.stringArray(forKey: "joined") ?? []).contains { $0.lowercased() == s.lowercased() } }
    static func set(_ s: String, _ yes: Bool) {
        var a = UserDefaults.standard.stringArray(forKey: "joined") ?? []
        a.removeAll { $0.lowercased() == s.lowercased() }
        if yes { a.append(s) }
        UserDefaults.standard.set(a, forKey: "joined")
    }
}

/// ☆ adds the subreddit to the home screen, ★ takes it off.
final class StarButton: UIBarButtonItem {
    private var name = ""

    convenience init(_ name: String) {
        self.init()
        self.name = name
        style = .plain
        target = self
        action = #selector(tap)
        show()
    }

    private func show() { title = Favorites.has(name) ? "★" : "☆" }

    @objc private func tap() {
        Favorites.toggle(name)
        show()
    }
}

/// The button always says what tapping it does: "Join" ⇄ "Leave" for a subreddit, "Follow" ⇄
/// "Unfollow" for a person — so there's always a clear way out, not just a "Joined ✓" state badge.
/// Toggles the subscription on your real account (following a person is just subscribing to u_<them>).
final class JoinButton: UIBarButtonItem {
    private var sr = ""           // the subreddit to (un)subscribe: a name, or "u_<user>" for a follow
    private var onWord = "Join"
    private var offWord = "Leave"
    private var joined: Bool?
    private var busy = false

    /// Join/leave a subreddit — reads "Join" when you're out, "Leave" when you're in.
    convenience init(_ name: String) { self.init(sr: name, on: "Join", off: "Leave") }

    /// Follow/unfollow a person — reads "Follow" when you're not, "Unfollow" when you are.
    convenience init(follow user: String) { self.init(sr: "u_" + user, on: "Follow", off: "Unfollow") }

    private convenience init(sr: String, on: String, off: String) {
        self.init()
        self.sr = sr
        self.onWord = on
        self.offWord = off
        style = .plain
        target = self
        action = #selector(tap)
        joined = Joined.has(sr)          // what you did in the app last time (the real check is blocked)
        show()
    }

    private func show() {
        guard !busy else { return }
        title = (joined == true) ? offWord : onWord
    }

    @objc private func tap() {
        guard !busy else { return }
        let want = !(joined == true)
        busy = true
        title = "…"
        Reddit.shared.subscribe(sr, join: want) { [weak self] err in
            guard let s = self else { return }
            s.busy = false
            if err == nil { s.joined = want; Joined.set(s.sr, want) }   // on failure, keep the prior state
            s.show()
            if let err = err, !err.isEmpty {
                let verb = s.onWord == "Follow" ? "follow" : "join"
                let a = UIAlertController(title: "Couldn't \(verb)", message: err, preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "OK", style: .default))
                topViewController()?.present(a, animated: true)
            }
        }
    }
}

/// A pencil (✎) in the nav bar that opens the composer to post to a specific subreddit.
final class ComposeButton: UIBarButtonItem {
    private var sub = ""

    convenience init(sub: String) {
        self.init(barButtonSystemItem: .compose, target: nil, action: nil)
        self.sub = sub
        target = self
        action = #selector(tap)
    }

    @objc private func tap() {
        topViewController()?.present(UINavigationController(rootViewController: SubmitVC(sr: sub)), animated: true)
    }
}
