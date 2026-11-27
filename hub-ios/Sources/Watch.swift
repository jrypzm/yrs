// Watching repositories for new releases — no login, and without spending the 60/hour API budget.
// GitHub publishes every repo's releases as a public Atom feed at github.com/<owner>/<repo>/releases.atom.
// It needs no account and is separate from the REST rate limit, so following repos is effectively free.
// The list of watched repos lives in UserDefaults; the feeds are cached briefly on disk like API replies.

import UIKit

/// The repos you follow, and the newest release you've already seen for each (to mark what's new).
enum Watchlist {
    private static let reposKey = "watch.repos"
    private static let seenKey = "watch.seen"
    private static var d: UserDefaults { .standard }

    /// Watched repos, "owner/name", most recently added first.
    static var repos: [String] { d.stringArray(forKey: reposKey) ?? [] }

    static func isWatching(_ full: String) -> Bool { repos.contains(full) }

    static func watch(_ full: String) {
        var r = repos
        guard !r.contains(full) else { return }
        r.insert(full, at: 0)
        d.set(r, forKey: reposKey)
    }

    static func unwatch(_ full: String) {
        d.set(repos.filter { $0 != full }, forKey: reposKey)
        var seen = seenMap
        seen[full] = nil
        d.set(seen, forKey: seenKey)
    }

    private static var seenMap: [String: String] { d.dictionary(forKey: seenKey) as? [String: String] ?? [:] }

    /// The release tag last shown to you for this repo.
    static func lastSeen(_ full: String) -> String? { seenMap[full] }

    static func markSeen(_ full: String, _ tag: String) {
        var m = seenMap
        m[full] = tag
        d.set(m, forKey: seenKey)
    }
}

/// A repository's releases, read from its public github.com Atom feed (no login, no API budget).
enum Atom {
    struct Release {
        let tag: String
        let title: String
        let updated: String   // ISO-8601; the feed lists releases newest first
        let url: String
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 15
        c.httpAdditionalHeaders = ["User-Agent": "yrs-hub", "Accept": "application/atom+xml"]
        return URLSession(configuration: c)
    }()

    /// Newest-first releases for `owner/name`. `cache` seconds serves a recent copy from disk, so
    /// re-opening the Watching screen costs nothing. nil means the fetch failed (offline, say).
    static func releases(_ full: String, cache: TimeInterval = 600, done: @escaping ([Release]?) -> Void) {
        guard let u = URL(string: "https://github.com/\(full)/releases.atom") else { done(nil); return }
        let key = "atom\n" + u.absoluteString
        if cache > 0, let cached = DiskCache.read(key, maxAge: cache) { done(parse(cached)); return }
        session.dataTask(with: u) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse).map { (200 ..< 300).contains($0.statusCode) } ?? false
            var out: [Release]?
            if ok, let data = data { DiskCache.write(key, data); out = parse(data) }
            DispatchQueue.main.async { done(out) }
        }.resume()
    }

    private static func parse(_ data: Data) -> [Release] {
        let p = FeedParser()
        let x = XMLParser(data: data)
        x.delegate = p
        x.parse()
        return p.releases
    }

    /// A small event-based parser: one Release per <entry>, with the tag taken from the entry's link.
    private final class FeedParser: NSObject, XMLParserDelegate {
        var releases: [Release] = []
        private var inEntry = false
        private var title = "", updated = "", id = "", url = ""
        private var buf = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            buf = ""
            if elementName == "entry" {
                inEntry = true; title = ""; updated = ""; id = ""; url = ""
            } else if inEntry, elementName == "link", attributeDict["rel"] == "alternate" || attributeDict["rel"] == nil {
                url = attributeDict["href"] ?? url
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { buf += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard inEntry else { return }
            let text = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "title": title = text
            case "updated": updated = text
            case "id": id = text
            case "entry":
                inEntry = false
                let raw = url.components(separatedBy: "/tag/").last ?? id.components(separatedBy: "/").last ?? ""
                let tag = raw.removingPercentEncoding ?? raw
                releases.append(Release(tag: tag, title: title, updated: updated, url: url))
            default: break
            }
        }
    }
}

/// The repos you watch, each showing its newest release — most recent first, with a mark on what's new.
final class WatchingVC: Feed {
    private var latest: [String: Atom.Release] = [:]
    private var failed: Set<String> = []

    init() { super.init("Watching") }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let r = UIRefreshControl()
        r.tintColor = .gray
        r.addTarget(self, action: #selector(refresh), for: .valueChanged)
        refreshControl = r
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()   // first show, and reflecting anything watched, unwatched, or newly seen since last time
    }

    @objc private func refresh() { load(force: true) }

    private func load(force: Bool = false) {
        let repos = Watchlist.repos
        guard !repos.isEmpty else {
            refreshControl?.endRefreshing()
            setHeader(nil)
            show([], note: "Not watching anything yet.\n\nOpen a repository and tap ☆ to follow it — its new releases show up here.")
            return
        }
        setHeader(NSAttributedString(string: "New releases from the repositories you watch. Pull to refresh; swipe a row to unwatch.",
                                     attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: Style.dim]))
        if items.isEmpty { show([], note: "Loading…") }

        var found: [String: Atom.Release] = [:]
        var missed: Set<String> = []
        let group = DispatchGroup()
        for full in repos {
            group.enter()
            Atom.releases(full, cache: force ? 0 : 600) { rels in
                if let rels = rels { if let first = rels.first { found[full] = first } }
                else { missed.insert(full) }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.latest = found
            self.failed = missed
            self.refreshControl?.endRefreshing()
            self.rebuild()
        }
    }

    private func rebuild() {
        let repos = Watchlist.repos
        let withRelease = repos.filter { latest[$0] != nil }.sorted { (latest[$0]?.updated ?? "") > (latest[$1]?.updated ?? "") }
        let without = repos.filter { latest[$0] == nil }
        let rows = (withRelease + without).map { full -> Item in
            if let r = latest[full] {
                var detail = r.tag.isEmpty ? "latest release" : r.tag
                let when = ago(r.updated)
                if !when.isEmpty { detail += "  ·  " + when }
                if !r.tag.isEmpty, Watchlist.lastSeen(full) != r.tag { detail = "● NEW   " + detail }
                return Item(title: full, detail: detail, open: {
                    Watchlist.markSeen(full, r.tag)
                    return RepoVC(full)
                })
            }
            return Item(title: full, detail: failed.contains(full) ? "couldn't check right now" : "no releases yet", open: { RepoVC(full) })
        }
        show(rows, note: nil)
    }

    // MARK: swipe to unwatch

    override func tableView(_ tableView: UITableView, canEditRowAt ip: IndexPath) -> Bool {
        items.indices.contains(ip.row)
    }

    override func tableView(_ tableView: UITableView, titleForDeleteConfirmationButtonForRowAt ip: IndexPath) -> String? { "Unwatch" }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt ip: IndexPath) {
        guard editingStyle == .delete, items.indices.contains(ip.row) else { return }
        let full = items[ip.row].title
        Watchlist.unwatch(full)
        latest[full] = nil
        failed.remove(full)
        rebuild()
    }
}
