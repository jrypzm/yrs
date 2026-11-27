// Every screen of the app, each one a list or a text built from GitHub's replies.

import UIKit

extension API {
    static let perPage = 40

    /// One page of a list; `key` when the list sits inside the reply (search results).
    func list(_ path: String, _ query: [String: String] = [:], page: Int, key: String? = nil, cache: TimeInterval = 0, parse: @escaping (JSON) -> Item?, done: @escaping Feed.Done) {
        var q = query
        q["per_page"] = "\(API.perPage)"
        q["page"] = "\(page)"
        json(path, q, cache: cache) { r in
            done(r.map { j in
                // unwrapped step by step: iOS 15 doesn't look inside an optional wrapped in Any
                let arr: [JSON]
                if let k = key, let obj = j as? JSON { arr = obj[k] as? [JSON] ?? [] } else { arr = j as? [JSON] ?? [] }
                return (arr.compactMap(parse), arr.count >= API.perPage)
            })
        }
    }
}

/// A list screen for one API list.
func listVC(_ title: String, _ path: String, _ query: [String: String] = [:], key: String? = nil, cache: TimeInterval = 0, parse: @escaping (JSON) -> Item?) -> Feed {
    Feed(title) { _, page, done in API.shared.list(path, query, page: page, key: key, cache: cache, parse: parse, done: done) }
}

private func repoOf(_ apiURL: String) -> String {
    let p = apiURL.components(separatedBy: "/repos/").last ?? ""
    return p.split(separator: "/").prefix(2).joined(separator: "/")
}

private func joined(_ bits: [String]) -> String { bits.filter { !$0.isEmpty }.joined(separator: " · ") }

// MARK: - rows

enum Make {
    static func repo(_ j: JSON) -> Item {
        let full = j.s("full_name")
        var bits = [j.s("language"), "★ " + count(j.i("stargazers_count"))]
        if j["fork"] as? Bool == true { bits.append("fork") }
        if j["private"] as? Bool == true { bits.append("private") }
        if j["archived"] as? Bool == true { bits.append("archived") }
        if !j.s("pushed_at").isEmpty { bits.append(ago(j.s("pushed_at"))) }
        let d = j.s("description")
        return Item(title: full, detail: (d.isEmpty ? "" : d + "\n") + joined(bits), open: { RepoVC(json: j) })
    }

    static func user(_ j: JSON) -> Item {
        let login = j.s("login")
        return Item(title: login, detail: j.s("type") == "Organization" ? "organization" : "", open: { UserVC(login) })
    }

    /// An issue or pull request, from the issues or search lists.
    static func issue(_ j: JSON, repo: String? = nil) -> Item {
        let r = repo ?? repoOf(j.s("repository_url"))
        let n = j.i("number")
        let pr = j["pull_request"] is JSON
        var state = j.s("state")
        if pr, !j.o("pull_request").s("merged_at").isEmpty { state = "merged" }
        if j["draft"] as? Bool == true { state = "draft" }
        let c = j.i("comments")
        let detail = joined([repo == nil ? r : "", "#\(n)", state, j.o("user").s("login"), ago(j.s("updated_at")), c > 0 ? "\(c) comments" : ""])
        return Item(title: j.s("title"), detail: detail, open: { ThreadVC(r, n, pr: pr) })
    }

    static func pull(_ j: JSON, repo: String) -> Item {
        let n = j.i("number")
        var state = j.s("state")
        if !j.s("merged_at").isEmpty { state = "merged" } else if j["draft"] as? Bool == true { state = "draft" }
        let branch = j.o("head").s("ref")
        return Item(title: j.s("title"), detail: joined(["#\(n)", state, j.o("user").s("login"), branch, ago(j.s("updated_at"))]), open: { ThreadVC(repo, n, pr: true) })
    }

    static func commit(_ j: JSON, repo: String) -> Item {
        let sha = j.s("sha")
        let c = j.o("commit")
        let msg = c.s("message")
        let first = msg.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? msg
        let who = j.o("author").s("login").isEmpty ? c.o("author").s("name") : j.o("author").s("login")
        return Item(title: first, detail: joined([String(sha.prefix(7)), who, ago(c.o("author").s("date"))]), open: { Screens.commit(repo, sha) })
    }

    static func release(_ j: JSON) -> Item {
        let name = j.s("name").isEmpty ? j.s("tag_name") : j.s("name")
        var bits = [j.s("tag_name"), ago(j.s("published_at"))]
        if j["prerelease"] as? Bool == true { bits.append("pre-release") }
        if j["draft"] as? Bool == true { bits.append("draft") }
        let n = (j["assets"] as? [JSON])?.count ?? 0
        if n > 0 { bits.append(n == 1 ? "1 file" : "\(n) files") }
        return Item(title: name, detail: joined(bits), open: { ReleaseVC(j) })
    }

    static func file(_ j: JSON, repo: String, ref: String) -> Item {
        let path = j.s("path"), name = j.s("name"), type = j.s("type")
        if type == "dir" { return Item(title: name + "/", open: { Screens.files(repo, path, ref: ref) }) }
        let size = j.i("size")
        let kb = size < 1024 ? "\(size) bytes" : "\(size / 1024) KB"
        return Item(title: name, detail: type == "file" ? kb : type, open: {
            // pictures, archives and very large files open on GitHub in Safari
            if size > 1_000_000 || Screens.binary.contains((name as NSString).pathExtension.lowercased()) {
                if let u = URL(string: j.s("html_url")) { UIApplication.shared.open(u) }
                return nil
            }
            return Screens.file(repo, path, ref: ref)
        }, dim: false)
    }

}

// MARK: - text screens

enum Screens {
    static let binary: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "ico", "icns", "bmp", "tiff", "heic", "pdf", "zip", "gz", "tgz", "xz", "bz2", "7z", "rar", "jar", "ipa", "apk", "dmg", "exe", "dll", "so", "dylib", "a", "o", "bin", "mp3", "mp4", "m4a", "mov", "wav", "flac", "ogg", "webm", "ttf", "otf", "woff", "woff2", "psd", "sketch", "car", "db", "sqlite"]

    static func files(_ repo: String, _ path: String, ref: String) -> Feed {
        let name = path.isEmpty ? "Code" : (path as NSString).lastPathComponent
        return Feed(name) { _, _, done in
            API.shared.json("repos/\(repo)/contents/\(path)", ref.isEmpty ? [:] : ["ref": ref], cache: 300) { r in
                done(r.map { j in
                    var arr = j as? [JSON] ?? []
                    arr.sort { a, b in
                        let da = a.s("type") == "dir", db = b.s("type") == "dir"
                        return da != db ? da : a.s("name").localizedStandardCompare(b.s("name")) == .orderedAscending
                    }
                    return (arr.map { Make.file($0, repo: repo, ref: ref) }, false)
                })
            }
        }
    }

    static func file(_ repo: String, _ path: String, ref: String) -> TextVC {
        let name = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        let md = ["md", "markdown", "mdown"].contains((name as NSString).pathExtension.lowercased())
        return TextVC(name, repo: repo, ref: ref, dir: dir) { done in
            API.shared.raw("repos/\(repo)/contents/\(path)", ref.isEmpty ? [:] : ["ref": ref], cache: 600) { r in
                done(r.map { text in
                    guard let text = text else {
                        return NSAttributedString(string: "This file isn't text.", attributes: [.font: Style.body, .foregroundColor: Style.dim])
                    }
                    return md ? Markdown.render(text).result : Code.render(text)
                })
            }
        }
    }

    /// A path inside a repository: a folder, or a file (by whether it has an extension).
    static func path(_ repo: String, _ path: String, ref: String, folder: Bool = false) -> UIViewController {
        if path.isEmpty { return RepoVC(repo) }
        let last = (path as NSString).lastPathComponent
        if folder || !last.contains(".") { return files(repo, path, ref: ref) }
        return file(repo, path, ref: ref)
    }

    static func readme(_ repo: String, ref: String) -> TextVC {
        TextVC("README", repo: repo, ref: ref) { done in
            API.shared.raw("repos/\(repo)/readme", cache: 900) { r in
                done(r.map { t in Markdown.render(t ?? "").result })
            }
        }
    }

    static func commit(_ repo: String, _ sha: String) -> TextVC {
        TextVC(String(sha.prefix(7)), repo: repo) { done in
            API.shared.json("repos/\(repo)/commits/\(sha)") { r in
                done(r.map { j in
                    let j = j as? JSON ?? [:]
                    let c = j.o("commit")
                    let d = Doc()
                    let msg = c.s("message")
                    let lines = msg.components(separatedBy: "\n")
                    d.text(lines.first ?? "", Style.bold(19), .white, Style.para(after: 6))
                    let rest = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !rest.isEmpty { d.text(rest, Style.body, Style.text) }
                    let who = j.o("author").s("login").isEmpty ? c.o("author").s("name") : j.o("author").s("login")
                    let st = j.o("stats")
                    let files = j["files"] as? [JSON] ?? []
                    d.text(joined([who, ago(c.o("author").s("date")), String(j.s("sha").prefix(7)), "\(files.count) files", "+\(st.i("additions")) −\(st.i("deletions"))"]), .systemFont(ofSize: 13), Style.dim, Style.para(after: 18))
                    for f in files {
                        Code.diff(file: f.s("filename"), status: f.s("status"), adds: f.i("additions"), dels: f.i("deletions"), patch: f["patch"] as? String, into: d)
                    }
                    return d.result
                })
            }
        }
    }

}

// MARK: - a release, with downloadable files

/// One release: its notes at the top, then each file as a row you tap to download (to Files / share).
final class ReleaseVC: Feed {
    private let j: JSON
    private var observation: NSKeyValueObservation?

    init(_ j: JSON) {
        self.j = j
        super.init(j.s("tag_name").isEmpty ? (j.s("name").isEmpty ? "Release" : j.s("name")) : j.s("tag_name"))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let j = self.j
        let d = Doc()
        d.text(j.s("name").isEmpty ? j.s("tag_name") : j.s("name"), Style.bold(20), .white, Style.para(after: 4))
        var bits = [j.s("tag_name"), j.o("author").s("login"), ago(j.s("published_at"))]
        if j["prerelease"] as? Bool == true { bits.append("pre-release") }
        d.text(joined(bits), .systemFont(ofSize: 13), Style.dim, Style.para(after: 14))
        let body = j.s("body")
        if !body.isEmpty { Markdown.render(body, into: d) }
        setHeader(d.result)

        let assets = j["assets"] as? [JSON] ?? []
        var rows: [Item] = assets.map { a in
            let kb = a.i("size") / 1024
            let size = kb >= 1024 ? String(format: "%.1f MB", Double(kb) / 1024) : "\(kb) KB"
            let dls = a.i("download_count")
            return Item(title: "⤓  " + a.s("name"),
                        detail: joined([size, dls > 0 ? "\(count(dls)) downloads" : ""]),
                        action: { [weak self] in self?.download(a) })
        }
        // the auto-generated source archive is always available
        if let zip = j["zipball_url"] as? String, !zip.isEmpty {
            rows.append(Item(title: "⤓  Source code (zip)", action: { [weak self] in
                self?.download(["browser_download_url": zip, "name": (j.s("tag_name").isEmpty ? "source" : j.s("tag_name")) + ".zip"])
            }))
        }
        if assets.isEmpty { rows.insert(Item(title: "No attached files — only the source code.", dim: true), at: 0) }
        rows.append(Item(title: "Open release on GitHub", action: {
            if let u = URL(string: j.s("html_url")) { UIApplication.shared.open(u) }
        }))
        show(rows)
    }

    /// Downloads an asset to a temp file at its real name, then offers the share sheet (Save to Files…).
    private func download(_ a: JSON) {
        guard let u = URL(string: a.s("browser_download_url")) else { return }
        let name = a.s("name").isEmpty ? (u.lastPathComponent.isEmpty ? "download" : u.lastPathComponent) : a.s("name")
        let progress = UIAlertController(title: "Downloading", message: name + "\n0%", preferredStyle: .alert)
        progress.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(progress, animated: true)
        let task = URLSession.shared.downloadTask(with: u) { [weak self] tmp, resp, err in
            DispatchQueue.main.async {
                self?.observation = nil
                guard let self = self, self.presentedViewController === progress else { return }   // cancelled or gone
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                progress.dismiss(animated: true) {
                    guard let tmp = tmp, err == nil, (200 ..< 400).contains(code) else {
                        self.tell("Couldn't download — \(err?.localizedDescription ?? "GitHub answered \(code).")")
                        return
                    }
                    let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                    try? FileManager.default.removeItem(at: dest)
                    do { try FileManager.default.moveItem(at: tmp, to: dest) } catch { self.tell("Couldn't save the file."); return }
                    let share = UIActivityViewController(activityItems: [dest], applicationActivities: nil)
                    share.popoverPresentationController?.sourceView = self.view
                    share.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1, height: 1)
                    self.present(share, animated: true)
                }
            }
        }
        observation = task.progress.observe(\.fractionCompleted) { p, _ in
            DispatchQueue.main.async { progress.message = name + "\n\(Int(p.fractionCompleted * 100))%" }
        }
        task.resume()
    }

    private func tell(_ t: String) {
        let a = UIAlertController(title: t, message: nil, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }
}

// MARK: - home

/// The whole app opens here: a search field in the middle, nothing else. Type and go.
final class SearchHomeVC: UIViewController, UISearchBarDelegate {
    private let name = UILabel()
    private let hint = UILabel()
    private let bar = UISearchBar()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigationItem.backButtonDisplayMode = .minimal
        name.text = "hub"
        name.font = .systemFont(ofSize: 46, weight: .bold)
        name.textColor = .white
        name.textAlignment = .center
        hint.text = "Search GitHub — a repo, a topic, or a user"
        hint.font = .systemFont(ofSize: 15)
        hint.textColor = Style.dim
        hint.textAlignment = .center
        hint.numberOfLines = 0
        bar.placeholder = "Search repositories"
        bar.searchBarStyle = .minimal
        bar.barStyle = .black
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        bar.returnKeyType = .search
        bar.delegate = self
        [name, hint, bar].forEach { view.addSubview($0) }
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard)))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = view.bounds.width, mid = view.bounds.height * 0.3
        name.frame = CGRect(x: 0, y: mid, width: w, height: 54)
        hint.frame = CGRect(x: 24, y: mid + 62, width: w - 48, height: 40)
        bar.frame = CGRect(x: 18, y: mid + 112, width: w - 36, height: 56)
    }

    @objc private func dismissKeyboard() { bar.resignFirstResponder() }

    func searchBarSearchButtonClicked(_ b: UISearchBar) {
        let q = (b.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        b.resignFirstResponder()
        if let u = Router.github(q) { Router.open(u, from: self, pasted: true); return }   // a pasted github.com link
        navigationController?.pushViewController(searchResults(q), animated: true)
    }
}

/// Where a search goes: `owner/repo` opens that repo; otherwise a sortable repo search. Type a word for
/// many related repos, or `user:name` for someone's repos (both ride the generous search budget).
func searchResults(_ q: String) -> UIViewController {
    let trimmed = q.trimmingCharacters(in: .whitespaces)
    let parts = trimmed.split(separator: "/")
    if parts.count == 2, !trimmed.contains(" "), !trimmed.contains(":") { return RepoVC("\(parts[0])/\(parts[1])") }
    let sorts = ["Best match", "Stars", "Forks", "Updated"]
    let keys = ["", "stars", "forks", "updated"]
    return Feed(trimmed, choices: sorts) { choice, page, done in
        var query = ["q": trimmed]
        if choice > 0 { query["sort"] = keys[choice]; query["order"] = "desc" }
        API.shared.list("search/repositories", query, page: page, key: "items", cache: 120, parse: Make.repo, done: done)
    }
}

// MARK: - a repository

final class RepoVC: Feed {
    let full: String
    private let preloaded: JSON?

    /// Opened by name (typed, or from a link): fetches the repo once, cached.
    init(_ full: String) {
        self.full = full
        self.preloaded = nil
        super.init(full.split(separator: "/").last.map(String.init) ?? full)
        fetch = { [weak self] _, _, done in self?.load(done) }
    }

    /// Opened from a search result: the JSON already has everything, so this costs no extra request.
    init(json j: JSON) {
        self.full = j.s("full_name")
        self.preloaded = j
        super.init(j.s("full_name").split(separator: "/").last.map(String.init) ?? j.s("full_name"))
        fetch = { [weak self] _, _, done in self?.load(done) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func load(_ done: @escaping Feed.Done) {
        if let j = preloaded {                       // from search: no request at all
            header(j)
            done(.success((rows(j), false)))
            return
        }
        API.shared.json("repos/\(full)", cache: 600) { [weak self] r in
            guard let s = self else { return }
            switch r {
            case .failure(let e): done(.failure(e))
            case .success(let j):
                let j = j as? JSON ?? [:]
                s.header(j)
                done(.success((s.rows(j), false)))
            }
        }
    }

    private func header(_ j: JSON) {
        let d = Doc()
        d.text(j.s("full_name"), Style.bold(20), .white, Style.para(after: 6))
        if !j.s("description").isEmpty { d.text(j.s("description"), Style.body, Style.text) }
        var bits = ["★ " + count(j.i("stargazers_count")), count(j.i("forks_count")) + " forks", "\(j.i("open_issues_count")) issues", j.s("language"), j.o("license").s("spdx_id")]
        if j["archived"] as? Bool == true { bits.append("archived") }
        bits.append("updated " + ago(j.s("pushed_at")))
        d.text(joined(bits.filter { $0 != "NOASSERTION" && $0 != "0 issues" }), .systemFont(ofSize: 13), Style.dim, Style.para(after: 2))
        let topics = (j["topics"] as? [String]) ?? []
        if !topics.isEmpty { d.text(topics.prefix(8).joined(separator: " · "), .systemFont(ofSize: 13), Style.link, Style.para(after: 2)) }
        if !j.s("homepage").isEmpty, let u = URL(string: j.s("homepage")) {
            d.add(NSAttributedString(string: j.s("homepage"), attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: Style.link, .link: u]))
        }
        setHeader(d.result)
    }

    private func rows(_ j: JSON) -> [Item] {
        let full = self.full
        let ref = j.s("default_branch")
        let owner = j.o("owner").s("login")
        var rows: [Item] = [
            Item(title: "Releases", detail: "download files", open: { listVC("Releases", "repos/\(full)/releases", cache: 300, parse: Make.release) }),
            Item(title: "README", open: { Screens.readme(full, ref: ref) }),
            Item(title: "Code", detail: ref, open: { Screens.files(full, "", ref: ref) }),
            Item(title: "Owner", detail: owner, open: { UserVC(owner) }),
        ]
        let parent = j.o("parent").s("full_name")
        if !parent.isEmpty { rows.append(Item(title: "Forked from", detail: parent, open: { RepoVC(parent) })) }
        rows.append(Item(title: "Open in Safari", detail: "github.com/\(full)", action: {
            if let u = URL(string: "https://github.com/\(full)") { UIApplication.shared.open(u) }
        }))
        return rows
    }
}

// MARK: - a person or an organization

final class UserVC: Feed {
    let login: String

    init(_ login: String) {
        self.login = login
        super.init(login)
        fetch = { [weak self] _, _, done in self?.load(done) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func load(_ done: @escaping Feed.Done) {
        let login = self.login
        API.shared.json("users/\(login)") { [weak self] r in
            guard let s = self else { return }
            switch r {
            case .failure(let e): done(.failure(e))
            case .success(let j):
                let j = j as? JSON ?? [:]
                let d = Doc()
                d.text(j.s("name").isEmpty ? login : j.s("name"), Style.bold(20), .white, Style.para(after: 2))
                if !j.s("name").isEmpty { d.text(login, .systemFont(ofSize: 14), Style.dim, Style.para(after: 8)) }
                if !j.s("bio").isEmpty { d.text(j.s("bio"), Style.body, Style.text) }
                d.text(joined([j.s("company"), j.s("location"), j.s("blog")]), .systemFont(ofSize: 13), Style.dim, Style.para(after: 2))
                d.text(joined(["\(count(j.i("followers"))) followers", "\(count(j.i("following"))) following", "\(j.i("public_repos")) repositories", "joined " + ago(j.s("created_at"))]), .systemFont(ofSize: 13), Style.dim)
                s.setHeader(d.result)
                let org = j.s("type") == "Organization"
                var rows: [Item] = [
                    Item(title: "Repositories", open: { listVC("Repositories", "users/\(login)/repos", ["sort": "pushed"], parse: Make.repo) }),
                ]
                if !org {
                    rows += [
                        Item(title: "Starred", open: { listVC("Starred", "users/\(login)/starred", parse: Make.repo) }),
                        Item(title: "Followers", open: { listVC("Followers", "users/\(login)/followers", parse: Make.user) }),
                        Item(title: "Following", open: { listVC("Following", "users/\(login)/following", parse: Make.user) }),
                        Item(title: "Organizations", open: { listVC("Organizations", "users/\(login)/orgs", parse: { o in
                            let n = o.s("login")
                            return Item(title: n, detail: o.s("description"), open: { UserVC(n) })
                        }) }),
                    ]
                } else {
                    rows.append(Item(title: "People", open: { listVC("People", "orgs/\(login)/members", parse: Make.user) }))
                }
                rows.append(Item(title: "Open in Safari", detail: "github.com/\(login)", action: {
                    if let u = URL(string: "https://github.com/\(login)") { UIApplication.shared.open(u) }
                }))
                done(.success((rows, false)))
            }
        }
    }
}

// MARK: - an issue or a pull request, with its comments

final class ThreadVC: UIViewController {
    let repo: String
    let number: Int
    let pr: Bool
    private var text: TextVC!

    init(_ repo: String, _ number: Int, pr: Bool) {
        self.repo = repo
        self.number = number
        self.pr = pr
        super.init(nibName: nil, bundle: nil)
        title = "#\(number)"
        navigationItem.backButtonDisplayMode = .minimal
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let repo = self.repo, number = self.number, pr = self.pr
        text = TextVC(title ?? "", repo: repo) { done in ThreadVC.load(repo, number, pr: pr, done: done) }
        addChild(text)
        text.view.frame = view.bounds
        text.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(text.view)
        text.didMove(toParent: self)
        if pr {
            navigationItem.rightBarButtonItems = [
                UIBarButtonItem(title: "Changes", style: .plain, target: self, action: #selector(changes)),
                UIBarButtonItem(title: "Commits", style: .plain, target: self, action: #selector(commits)),
            ]
        }
    }

    @objc private func changes() {
        let repo = self.repo, number = self.number
        navigationController?.pushViewController(TextVC("Changes", repo: repo) { done in
            API.shared.json("repos/\(repo)/pulls/\(number)/files", ["per_page": "100"]) { r in
                done(r.map { j in
                    let files = j as? [JSON] ?? []
                    let d = Doc()
                    let adds = files.reduce(0) { $0 + $1.i("additions") }, dels = files.reduce(0) { $0 + $1.i("deletions") }
                    d.text("\(files.count)\(files.count == 100 ? "+" : "") files changed · +\(adds) −\(dels)", .systemFont(ofSize: 13), Style.dim, Style.para(after: 16))
                    for f in files {
                        Code.diff(file: f.s("filename"), status: f.s("status"), adds: f.i("additions"), dels: f.i("deletions"), patch: f["patch"] as? String, into: d)
                    }
                    return d.result
                })
            }
        }, animated: true)
    }

    @objc private func commits() {
        let repo = self.repo
        navigationController?.pushViewController(listVC("Commits", "repos/\(repo)/pulls/\(number)/commits", parse: { Make.commit($0, repo: repo) }), animated: true)
    }

    private static func load(_ repo: String, _ n: Int, pr: Bool, done: @escaping (Result<NSAttributedString, APIError>) -> Void) {
        API.shared.json("repos/\(repo)/issues/\(n)") { r in
            switch r {
            case .failure(let e): done(.failure(e))
            case .success(let j):
                let j = j as? JSON ?? [:]
                let finish = { (extra: String, comments: [JSON]) in
                    let d = Doc()
                    d.text(j.s("title"), Style.bold(20), .white, Style.para(after: 6))
                    var state = j.s("state")
                    if pr, !j.o("pull_request").s("merged_at").isEmpty { state = "merged" }
                    d.text(joined([repo + " #\(n)", state, j.o("user").s("login"), ago(j.s("created_at"))]), .systemFont(ofSize: 13), Style.dim, Style.para(after: extra.isEmpty ? 6 : 2))
                    if !extra.isEmpty { d.text(extra, .systemFont(ofSize: 13), Style.dim, Style.para(after: 6)) }
                    let labels = (j["labels"] as? [JSON] ?? []).map { $0.s("name") }
                    if !labels.isEmpty { d.text(labels.joined(separator: " · "), .systemFont(ofSize: 13), Style.link, Style.para(after: 6)) }
                    d.gap(6)
                    let body = j.s("body")
                    if body.isEmpty { d.text("No description.", Style.body, Style.dim) } else { Markdown.render(body, into: d) }
                    for c in comments {
                        d.gap(10)
                        d.text("─────", Style.body, UIColor(white: 0.25, alpha: 1), Style.para(after: 6))
                        d.text(joined([c.o("user").s("login"), ago(c.s("created_at"))]), Style.bold(13), Style.dim, Style.para(after: 6))
                        Markdown.render(c.s("body"), into: d)
                    }
                    if comments.count == 100 { d.gap(); d.text("Only the first 100 comments are shown.", .systemFont(ofSize: 13), Style.dim) }
                    done(.success(d.result))
                }
                let getComments = { (extra: String) in
                    if j.i("comments") == 0 { finish(extra, []); return }
                    API.shared.json("repos/\(repo)/issues/\(n)/comments", ["per_page": "100"]) { r in
                        finish(extra, (try? r.get()) as? [JSON] ?? [])
                    }
                }
                guard pr else { getComments(""); return }
                // a pull request: its branches and size too
                API.shared.json("repos/\(repo)/pulls/\(n)") { r in
                    let p = (try? r.get()) as? JSON ?? [:]
                    let extra = p.isEmpty ? "" : joined(["\(p.o("head").s("label")) → \(p.o("base").s("ref"))", "\(p.i("commits")) commits", "\(p.i("changed_files")) files", "+\(p.i("additions")) −\(p.i("deletions"))", p["draft"] as? Bool == true ? "draft" : ""])
                    getComments(extra)
                }
            }
        }
    }
}
