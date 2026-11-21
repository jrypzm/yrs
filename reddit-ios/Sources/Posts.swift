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

    static func sub(_ name: String) -> Feed {
        let f = feed("r/" + name, choices: sorts) { sortPath("/r/" + name, $0) }
        f.navigationItem.title = "r/" + name
        f.navigationItem.rightBarButtonItem = StarButton(name)
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
        feed("u/" + name, choices: ["New", "Top"]) { c in ("/user/\(name)/submitted", ["sort": c == 0 ? "new" : "top"]) }
    }

    static func search(_ q: String) -> Feed {
        feed(q, choices: ["Subreddits", "Posts"]) { c in
            c == 0 ? ("/subreddits/search", ["q": q]) : ("/search", ["q": q, "sort": "relevance"])
        }
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
