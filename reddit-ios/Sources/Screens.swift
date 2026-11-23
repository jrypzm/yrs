// The screens: home, a post with its comments, the picture viewer, video, signing in, links.

import AVKit
import SafariServices
import UIKit
import WebKit

// MARK: - home

final class HomeVC: Feed, UISearchBarDelegate {
    private let bar = UISearchBar()

    init() {
        super.init("Menu")
        NotificationCenter.default.addObserver(self, selector: #selector(build), name: Reddit.signedIn, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        bar.placeholder = "Subreddit, search, or paste a link"
        bar.searchBarStyle = .minimal
        bar.barStyle = .black
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        bar.delegate = self
        bar.sizeToFit()
        tableView.tableHeaderView = bar
        tableView.keyboardDismissMode = .onDrag
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        build()   // stars may have changed
    }

    func searchBarSearchButtonClicked(_ b: UISearchBar) {
        let q = (b.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        b.resignFirstResponder()
        if let vc = HomeVC.destination(q) { navigationController?.pushViewController(vc, animated: true) }
    }

    /// "r/pics" or "pics" opens it, "u/name" a person, a link its page; anything else is searched.
    static func destination(_ q: String) -> UIViewController? {
        let low = q.lowercased()
        if low.contains("reddit.com") || low.contains("redd.it"), let u = URL(string: q.hasPrefix("http") ? q : "https://" + q) {
            return Router.screen(u)
        }
        if low.hasPrefix("r/") || low.hasPrefix("/r/") { return Lists.sub(String(q.split(separator: "/").last ?? "")) }
        if low.hasPrefix("u/") || low.hasPrefix("/u/") { return Lists.user(String(q.split(separator: "/").last ?? "")) }
        return Lists.search(q)
    }

    @objc private func build() {
        var rows: [Item] = [
            Item(title: "Popular", detail: "What's popular across Reddit", open: { Lists.sub("popular") }),
            Item(title: "All", detail: "The newest from everywhere", open: { Lists.sub("all") }),
        ]
        for s in Favorites.all {
            rows.append(Item(title: "r/" + s, detail: "★ saved", open: { Lists.sub(s) }))
        }
        rows.append(Item(title: "Open a Reddit link", detail: "Paste a link to a post, subreddit or person.", action: { [weak self] in self?.openLink() }))
        if Reddit.shared.isSignedIn {
            rows.append(Item(title: "New post", detail: "Write a text post to a subreddit", action: { [weak self] in
                self?.present(UINavigationController(rootViewController: SubmitVC()), animated: true)
            }))
            rows.append(Item(title: "Your front page", detail: "From the subreddits you follow", open: { Lists.front() }))
            rows.append(Item(title: "Subreddits you follow", open: { Lists.feed("Following") { _ in ("/subreddits/mine/subscriber", [:]) } }))
            rows.append(Item(title: "Sign out", action: { [weak self] in
                let a = UIAlertController(title: "Sign out?", message: nil, preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                a.addAction(UIAlertAction(title: "Sign out", style: .destructive) { _ in Reddit.shared.signOut() })
                self?.present(a, animated: true)
            }))
        } else {
            rows.append(Item(title: "Sign in", detail: "Unlocks your front page, your subs, and the feeds Reddit won't show a logged-out app. Your password goes only to Reddit.", action: { [weak self] in
                let nav = UINavigationController(rootViewController: LoginVC())
                nav.modalPresentationStyle = .fullScreen
                self?.present(nav, animated: true)
            }))
        }
        show(rows)
    }

    private func openLink(_ error: String? = nil) {
        let a = UIAlertController(title: "Open a Reddit link", message: error ?? "Paste a link to a post, subreddit or person.", preferredStyle: .alert)
        a.addTextField { f in
            f.placeholder = "https://www.reddit.com/r/…"
            f.keyboardType = .URL
            f.autocorrectionType = .no
            f.autocapitalizationType = .none
            f.clearButtonMode = .always
            if UIPasteboard.general.hasStrings, let c = UIPasteboard.general.string, c.contains("reddit.com") || c.contains("redd.it") {
                f.text = c.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Open", style: .default) { [weak self, weak a] _ in
            let t = (a?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            if let vc = HomeVC.destination(t) { self?.navigationController?.pushViewController(vc, animated: true) } else { self?.openLink("That isn't a Reddit link. Try again.") }
        })
        present(a, animated: true)
    }
}

// MARK: - a post and its comments

final class PostVC: UIViewController, UITextViewDelegate {
    private var post: Post
    private var comments: [JSON]?
    private var failure: String?
    private let tv = UITextView()
    private let picture = UIImageView()
    private let badge = UILabel()
    private var media = Media.none
    private var joinSet = false

    init(_ p: Post) {
        post = p
        super.init(nibName: nil, bundle: nil)
        title = "r/" + p.sub
        navigationItem.backButtonDisplayMode = .minimal
    }

    /// A post known only by its link.
    convenience init(permalink: String) {
        self.init(Post(j: ["permalink": permalink]))
        title = "Post"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        tv.backgroundColor = .black
        tv.isEditable = false
        tv.isSelectable = true          // required for the r/sub, u/author and reply links to be tappable
        tv.indicatorStyle = .white
        tv.dataDetectorTypes = []
        tv.delegate = self
        tv.linkTextAttributes = [.foregroundColor: Style.link]
        tv.alwaysBounceVertical = true
        tv.layoutManager.allowsNonContiguousLayout = true
        picture.contentMode = .scaleAspectFit
        picture.backgroundColor = UIColor(white: 0.07, alpha: 1)
        picture.clipsToBounds = true
        picture.layer.cornerRadius = 8
        picture.isUserInteractionEnabled = true
        picture.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openMedia)))
        badge.font = .systemFont(ofSize: 13, weight: .semibold)
        badge.textColor = .white
        badge.backgroundColor = UIColor(white: 0, alpha: 0.65)
        badge.textAlignment = .center
        badge.layer.cornerRadius = 6
        badge.clipsToBounds = true
        picture.addSubview(badge)
        tv.addSubview(picture)
        view = tv
        let r = UIRefreshControl()
        r.tintColor = .gray
        r.addTarget(self, action: #selector(load), for: .valueChanged)
        tv.refreshControl = r
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
        load()
    }

    /// A "Join" button for this post's subreddit, added once its name is known (right after it loads).
    private func setJoin() {
        guard !joinSet, Reddit.shared.isSignedIn, !post.sub.isEmpty else { return }
        joinSet = true
        navigationItem.rightBarButtonItem = JoinButton(post.sub)
    }

    @objc private func load() {
        guard !post.permalink.isEmpty else { return }
        Reddit.shared.get(post.permalink, ["limit": "50", "depth": "5"]) { [weak self] r in
            guard let s = self else { return }
            s.tv.refreshControl?.endRefreshing()
            switch r {
            case .success(let j):
                let parts = j as? [JSON] ?? []
                if let d = parts.first?.o("data").a("children").first?.o("data"), !d.isEmpty {
                    s.post = Post(j: d)
                    s.title = "r/" + s.post.sub
                }
                s.comments = parts.count > 1 ? parts[1].o("data").a("children") : []
                s.failure = nil
            case .failure(let e):
                s.failure = e.description
            }
            s.render()
        }
    }

    private var width: CGFloat { max(view.bounds.width, 320) }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPicture()
    }

    private func layoutPicture() {
        let w = width - 20
        let ratio: CGFloat
        switch media {
        case .none: ratio = 0
        case .image(let p, _): ratio = p.ratio
        case .gallery(let ps, _): ratio = ps.first?.ratio ?? 1
        case .video(_, let p): ratio = p?.ratio ?? 0.5625
        }
        let h = ratio == 0 ? 0 : min(w * ratio, w * 1.4)
        picture.isHidden = h == 0
        picture.frame = CGRect(x: 10, y: 10, width: w, height: h)
        badge.sizeToFit()
        badge.frame = CGRect(x: w - badge.bounds.width - 26, y: h - 34, width: badge.bounds.width + 16, height: 24)
        badge.isHidden = badge.text?.isEmpty ?? true
        let top = h == 0 ? 14 : h + 24
        if tv.textContainerInset.top != top { tv.textContainerInset = UIEdgeInsets(top: top, left: 10, bottom: 30, right: 10) }
    }

    private func render() {
        let px = (width - 20) * UIScreen.main.scale
        media = post.j.isEmpty || post.title.isEmpty ? .none : post.media(px: px)
        var pic: Pic?
        switch media {
        case .none: badge.text = nil
        case .image(let p, _): pic = p; badge.text = nil
        case .gallery(let ps, _): pic = ps.first; badge.text = "1 of \(ps.count) · tap for all"
        case .video(_, let p): pic = p; badge.text = "▶ play"
        }
        if let p = pic, picture.image == nil || picture.tag != p.url.hashValue {
            picture.tag = p.url.hashValue
            Images.load(p.url, px: px) { [weak self] img in
                guard let s = self, s.picture.tag == p.url.hashValue else { return }
                s.picture.image = img
            }
        }
        layoutPicture()

        setJoin()
        let d = Doc()
        if !post.title.isEmpty {
            d.text(post.title, Style.bold(19), .white, Style.para(after: 6))
            let j = post.j
            // r/sub and u/author are tappable — they open the subreddit and the person's page
            let small = UIFont.systemFont(ofSize: 13)
            let dim: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: Style.dim]
            let line = NSMutableAttributedString()
            if !post.sub.isEmpty, let u = URL(string: "https://www.reddit.com/r/\(post.sub)") {
                line.append(NSAttributedString(string: "r/" + post.sub, attributes: [.font: small, .foregroundColor: Style.link, .link: u]))
                line.append(NSAttributedString(string: " · ", attributes: dim))
            }
            if !post.author.isEmpty, post.author != "[deleted]", let u = URL(string: "https://www.reddit.com/user/\(post.author)") {
                line.append(NSAttributedString(string: "u/" + post.author, attributes: [.font: small, .foregroundColor: Style.link, .link: u]))
                line.append(NSAttributedString(string: " · ", attributes: dim))
            }
            line.append(NSAttributedString(string: joined([count(j.i("score")) + " points", ago(j.d("created_utc"))]), attributes: dim))
            d.add(line, Style.para(after: 2))
            let tags = joined([post.nsfw ? "NSFW" : "", j.b("spoiler") ? "spoiler" : "", j.s("link_flair_text")])
            if !tags.isEmpty { d.text(tags, .systemFont(ofSize: 13), Style.link, Style.para(after: 2)) }
            d.gap(6)
            let body = j.s("selftext")
            if !body.isEmpty { Markdown.render(body, into: d) }
            if !post.isSelf, case .none = media, let u = URL(string: post.link) {
                d.add(NSAttributedString(string: post.link, attributes: [.font: Style.body, .foregroundColor: Style.link, .link: u]))
            }
        }
        if let f = failure {
            d.gap(8)
            d.text(f, Style.body, Style.dim)
        } else if let cs = comments {
            d.gap(12)
            if Reddit.shared.isSignedIn, !post.id.isEmpty, let u = URL(string: "yrsreply:t3_\(post.id)") {
                d.add(NSAttributedString(string: "＋ Add a comment", attributes: [.font: Style.bold(14), .foregroundColor: Style.link, .link: u]), Style.para(after: 10))
            }
            d.text(cs.isEmpty ? "No comments yet." : "\(count(post.j.i("num_comments"))) comments", Style.bold(15), Style.dim, Style.para(after: 10))
            CommentDoc.render(cs, linkID: post.id.isEmpty ? "" : "t3_" + post.id, into: d)
        } else {
            d.gap(12)
            d.text("Loading comments…", Style.body, Style.dim)
        }
        tv.attributedText = d.result
    }

    @objc private func openMedia() {
        switch media {
        case .none: break
        case .image(_, let full): present(ViewerVC([full]), animated: true)
        case .gallery(_, let full): present(ViewerVC(full), animated: true)
        case .video(let u, _): play(u, from: self)
        }
    }

    @objc private func inSafari() { Safari.open(post.permalink, from: self) }

    func textView(_ textView: UITextView, shouldInteractWith url: URL, in range: NSRange, interaction: UITextItemInteraction) -> Bool {
        if interaction == .invokeDefaultAction {
            if url.scheme == "yrsreply" {
                compose(replyTo: String(url.absoluteString.dropFirst("yrsreply:".count)))
            } else {
                Router.open(url, from: self)
            }
        }
        return false
    }

    /// Opens the reply composer for a post or comment (its fullname); reloads to show the reply.
    private func compose(replyTo fullname: String) {
        guard Reddit.shared.isSignedIn else { return }
        let c = ComposeVC(title: "Reply", hint: "Your reply…") { [weak self] text, done in
            Reddit.shared.reply(to: fullname, text: text) { err in
                done(err)
                if err == nil { self?.load() }
            }
        }
        present(UINavigationController(rootViewController: c), animated: true)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        if view.window == nil { picture.image = nil }
    }
}

/// Videos play in the system player, which is loaded only when you tap play.
func play(_ u: URL, from vc: UIViewController) {
    try? AVAudioSession.sharedInstance().setCategory(.playback)
    let p = AVPlayerViewController()
    p.player = AVPlayer(url: u)
    vc.present(p, animated: true) { p.player?.play() }
}

// MARK: - pictures, full screen

/// Swipe between pictures, pinch to zoom. Only the picture on screen and its neighbours are kept.
final class ViewerVC: UIViewController, UIScrollViewDelegate {
    private let urls: [URL]
    private let pager = UIScrollView()
    private var pages: [ZoomPage] = []
    private let counter = UILabel()
    private var current = -1

    init(_ urls: [URL]) {
        self.urls = urls
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.delegate = self
        pager.contentInsetAdjustmentBehavior = .never
        view.addSubview(pager)
        for _ in urls {
            let p = ZoomPage()
            pages.append(p)
            pager.addSubview(p)
        }
        let close = UIButton(type: .system)
        close.setTitle("Close", for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        close.tintColor = .white
        close.frame = CGRect(x: 16, y: 20, width: 70, height: 40)
        close.addTarget(self, action: #selector(done), for: .touchUpInside)
        view.addSubview(close)
        counter.textColor = UIColor(white: 0.7, alpha: 1)
        counter.font = .systemFont(ofSize: 15)
        counter.textAlignment = .right
        view.addSubview(counter)
        let down = UISwipeGestureRecognizer(target: self, action: #selector(done))
        down.direction = .down
        view.addGestureRecognizer(down)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let b = view.bounds
        pager.frame = b
        pager.contentSize = CGSize(width: b.width * CGFloat(urls.count), height: b.height)
        for (i, p) in pages.enumerated() { p.frame = CGRect(x: b.width * CGFloat(i), y: 0, width: b.width, height: b.height) }
        counter.frame = CGRect(x: b.width - 116, y: 20, width: 100, height: 40)
        show(Int(round(pager.contentOffset.x / max(b.width, 1))))
    }

    func scrollViewDidEndDecelerating(_ s: UIScrollView) {
        show(Int(round(s.contentOffset.x / max(s.bounds.width, 1))))
    }

    private func show(_ i: Int) {
        let i = max(0, min(i, urls.count - 1))
        guard i != current else { return }
        current = i
        counter.text = urls.count > 1 ? "\(i + 1) of \(urls.count)" : ""
        let px = max(view.bounds.width, view.bounds.height) * UIScreen.main.scale
        for (k, p) in pages.enumerated() {
            if abs(k - i) <= 1 { p.show(urls[k], px: px) } else { p.clear() }
        }
    }

    @objc private func done() { dismiss(animated: true) }
}

final class ZoomPage: UIScrollView, UIScrollViewDelegate {
    private let iv = UIImageView()
    private var url: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        iv.contentMode = .scaleAspectFit
        addSubview(iv)
        let dbl = UITapGestureRecognizer(target: self, action: #selector(toggleZoom))
        dbl.numberOfTapsRequired = 2
        addGestureRecognizer(dbl)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == 1 { iv.frame = bounds }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { iv }

    @objc private func toggleZoom() { setZoomScale(zoomScale > 1 ? 1 : 2.5, animated: true) }

    func show(_ u: URL, px: CGFloat) {
        guard url != u else { return }
        url = u
        Images.load(u, px: px) { [weak self] img in
            guard let s = self, s.url == u else { return }
            s.iv.image = img
        }
    }

    func clear() {
        url = nil
        iv.image = nil
        zoomScale = 1
    }
}

// MARK: - signing in

// MARK: - links

enum Router {
    /// The screen for a Reddit link, or nil if it isn't one this app shows.
    static func screen(_ url: URL) -> UIViewController? {
        let host = (url.host ?? "www.reddit.com").lowercased()
        let parts = url.path.split(separator: "/").map(String.init)
        if host == "redd.it", parts.count == 1 { return PostVC(permalink: "/comments/" + parts[0]) }
        if host == "i.redd.it" || host == "preview.redd.it" { return nil }
        guard host.hasSuffix("reddit.com") else { return nil }
        // a link that points at one comment (…/comments/ID/title/COMMENTID) keeps its full path,
        // so tapping "continue this thread" opens that exact sub-conversation, not the post from the top
        if parts.count >= 6, parts[0] == "r", parts[2] == "comments" { return PostVC(permalink: url.path) }
        if parts.count >= 4, parts[0] == "r", parts[2] == "comments" { return PostVC(permalink: "/r/\(parts[1])/comments/\(parts[3])") }
        if parts.count >= 4, parts[0] == "comments" { return PostVC(permalink: url.path) }
        if parts.count >= 2, parts[0] == "comments" { return PostVC(permalink: "/comments/" + parts[1]) }
        if parts.count >= 2, parts[0] == "r", parts.count == 2 || ["hot", "new", "top", "rising"].contains(parts[2]) { return Lists.sub(parts[1]) }
        if parts.count >= 2, parts[0] == "u" || parts[0] == "user" { return Lists.user(parts[1]) }
        return nil
    }

    static func open(_ url: URL, from vc: UIViewController) {
        // "load more replies" link: yrsmore:t3_LINKID/child1,child2,… — fetch those comments in-app
        if url.scheme == "yrsmore" {
            let body = String(url.absoluteString.dropFirst("yrsmore:".count))
            let bits = body.split(separator: "/", maxSplits: 1).map(String.init)
            if bits.count == 2 {
                let kids = bits[1].split(separator: ",").map(String.init)
                vc.navigationController?.pushViewController(MoreVC(linkID: bits[0], children: kids), animated: true)
            }
            return
        }
        var u = url
        if u.host == nil, let r = URL(string: "https://www.reddit.com" + (u.path.hasPrefix("/") ? u.path : "/" + u.path)) { u = r }
        let host = (u.host ?? "").lowercased()
        if host == "i.redd.it" || (host == "i.imgur.com" && ["jpg", "jpeg", "png"].contains(u.pathExtension.lowercased())) {
            vc.present(ViewerVC([u]), animated: true)
            return
        }
        if host == "v.redd.it" { UIApplication.shared.open(u); return }
        if let next = screen(u) { vc.navigationController?.pushViewController(next, animated: true); return }
        UIApplication.shared.open(u)
    }
}

// MARK: - the ⋯ button

/// Plain three dots (no icon, no background) that run an action when tapped.
final class MenuDots: UIBarButtonItem {
    private var run: () -> Void = {}

    convenience init(_ run: @escaping () -> Void) {
        self.init()
        self.run = run
        let b = UIButton(type: .system)
        b.setTitle("⋯", for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 28)
        b.tintColor = .white
        b.backgroundColor = .clear
        b.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        b.addTarget(self, action: #selector(tap), for: .touchUpInside)
        customView = b
    }

    @objc private func tap() { run() }
}


// MARK: - signing in

/// Reddit's own sign-in page. Your password goes only to reddit.com; the app keeps no copy.
/// After this, every request is a plain fast HTTP call using your account token — no web view.
final class LoginVC: UIViewController, WKNavigationDelegate {
    private var web: WKWebView!
    private var done = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sign in to Reddit"
        view.backgroundColor = .black
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()
        c.applicationNameForUserAgent = safariSuffix
        web = WKWebView(frame: view.bounds, configuration: c)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.navigationDelegate = self
        view.addSubview(web)
        // old.reddit's login is a light HTML form that loads fast on iOS 15 (the new one hangs)
        web.load(URLRequest(url: URL(string: "https://old.reddit.com/login/")!))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(tapDone))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        whoAmI { [weak self] name in if name != nil { self?.finish() } }
    }

    private func whoAmI(_ then: @escaping (String?) -> Void) {
        let js = "try { const r = await fetch('/api/me.json', {credentials:'include'}); const j = await r.json(); return (j && j.data && j.data.name) ? j.data.name : ''; } catch(e) { return ''; }"
        web.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            if case .success(let v) = result, let name = v as? String, !name.isEmpty { then(name) } else { then(nil) }
        }
    }

    @objc private func cancel() { dismiss(animated: true) }

    @objc private func tapDone() {
        whoAmI { [weak self] name in
            if name != nil { self?.finish() } else {
                let a = UIAlertController(title: "Not signed in yet", message: "Log in on this page until you see your own Reddit, then tap Done.", preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(a, animated: true)
            }
        }
    }

    private func finish() {
        guard !done else { return }
        done = true
        Reddit.shared.signedIn(true)
        web.navigationDelegate = nil
        web = nil
        dismiss(animated: true)
    }
}

// MARK: - the real Safari engine

/// Opens a reddit.com path in the iPhone's own Safari engine, which uses your real Safari session
/// (so comments, search and NSFW work the way they do when you browse Reddit in Safari).
enum Safari {
    static func open(_ path: String, from vc: UIViewController) {
        let p = path.hasPrefix("/") ? path : "/" + path
        guard let u = URL(string: "https://old.reddit.com" + p) else { return }
        let s = SFSafariViewController(url: u)
        s.preferredBarTintColor = .black
        s.preferredControlTintColor = .white
        s.dismissButtonStyle = .close
        vc.present(s, animated: true)
    }
}

// MARK: - comments

/// Lays comment threads into a Doc. Shared by the post screen and the "load more" screen, so a
/// reply reads the same wherever it appears. A collapsed branch becomes a tappable link that
/// loads the rest in the app — never the browser.
enum CommentDoc {
    /// `linkID` is the post's fullname (t3_…), used to fetch collapsed replies. `baseDepth` pulls a
    /// sub-conversation back to the left margin so a drilled-in thread doesn't start half-way across.
    static func render(_ children: [JSON], linkID: String, baseDepth: Int = 0, into d: Doc) {
        for c in children { one(c, linkID: linkID, baseDepth: baseDepth, into: d) }
    }

    private static func indent(_ depth: Int, _ base: Int) -> CGFloat { CGFloat(min(max(depth - base, 0), 6)) * 14 }

    private static func one(_ c: JSON, linkID: String, baseDepth: Int, into d: Doc) {
        let kind = c.s("kind")
        let j = c.o("data")
        let depth = j.i("depth")
        if kind == "more" {
            d.indent = indent(depth, baseDepth)
            // Reddit's "load more" API (morechildren) is one of the blocked endpoints, so instead open
            // the parent comment's own page — a comment permalink, which old.reddit still serves — and
            // it carries that whole sub-conversation (the collapsed replies included).
            let parent = j.s("parent_id")
            let cid = parent.hasPrefix("t1_") ? String(parent.dropFirst(3)) : ""
            let post = linkID.hasPrefix("t3_") ? String(linkID.dropFirst(3)) : ""
            if !cid.isEmpty, !post.isEmpty, let u = URL(string: "https://old.reddit.com/comments/\(post)/_/\(cid)") {
                let n = j.i("count")
                let label = n > 0 ? "→ \(count(n)) more " + (n == 1 ? "reply" : "replies") : "→ continue this thread"
                d.add(NSAttributedString(string: label, attributes: [.font: Style.body, .foregroundColor: Style.link, .link: u]))
                d.gap(6)
            }
            d.indent = 0
            return
        }
        guard kind == "t1" else { return }
        d.indent = indent(depth, baseDepth)
        let shade = UIColor(white: max(0.32, 0.55 - CGFloat(max(depth - baseDepth, 0)) * 0.04), alpha: 1)
        let headStr = joined(["u/" + j.s("author"), count(j.i("score")) + " points", ago(j.d("created_utc"))]) + (j.b("is_submitter") ? " · OP" : "")
        let head = NSMutableAttributedString(string: headStr, attributes: [.font: Style.bold(13), .foregroundColor: shade])
        if Reddit.shared.isSignedIn, !j.s("id").isEmpty, let u = URL(string: "yrsreply:t1_\(j.s("id"))") {
            head.append(NSAttributedString(string: "   reply", attributes: [.font: Style.bold(13), .foregroundColor: Style.link, .link: u]))
        }
        d.add(head, Style.para(after: 3))
        Markdown.render(j.s("body"), into: d)
        d.gap(4)
        for r in j.o("replies").o("data").a("children") { one(r, linkID: linkID, baseDepth: baseDepth, into: d) }
        d.indent = 0
    }
}

/// The screen a "load more replies" link opens: fetches just those comments (old.reddit's
/// morechildren, your cookies) and lays them out like any other thread, in the app.
final class MoreVC: UIViewController, UITextViewDelegate {
    private let linkID: String
    private let childIDs: [String]
    private let tv = UITextView()
    private var things: [JSON] = []
    private var note: String?

    init(linkID: String, children: [String]) {
        self.linkID = linkID
        self.childIDs = children
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "More comments"
        view.backgroundColor = .black
        tv.frame = view.bounds
        tv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tv.backgroundColor = .black
        tv.isEditable = false
        tv.alwaysBounceVertical = true
        tv.textContainerInset = UIEdgeInsets(top: 14, left: 10, bottom: 30, right: 10)
        tv.delegate = self
        view.addSubview(tv)
        tv.attributedText = NSAttributedString(string: "Loading…", attributes: [.font: Style.body, .foregroundColor: Style.dim])
        load()
    }

    private func load() {
        let q = ["api_type": "json", "link_id": linkID, "children": childIDs.prefix(100).joined(separator: ","), "limit_children": "false"]
        Reddit.shared.get("/api/morechildren", q) { [weak self] r in
            guard let s = self else { return }
            switch r {
            case .success(let j):
                s.things = (j as? JSON)?.o("json").o("data").a("things") ?? []
                s.note = s.things.isEmpty ? "Nothing more to load here." : nil
            case .failure(let e):
                s.note = e.description
            }
            s.render()
        }
    }

    private func render() {
        let d = Doc()
        if let note = note {
            d.text(note, Style.body, Style.dim)
        } else {
            let base = things.map { $0.o("data").i("depth") }.min() ?? 0
            CommentDoc.render(things, linkID: linkID, baseDepth: base, into: d)
        }
        tv.attributedText = d.result
    }

    func textView(_ textView: UITextView, shouldInteractWith url: URL, in range: NSRange, interaction: UITextItemInteraction) -> Bool {
        if interaction == .invokeDefaultAction { Router.open(url, from: self) }
        return false
    }
}

// MARK: - writing (replies and new posts)

/// A plain composer for a reply. Cancel / Send in the nav bar; the text is posted through the web view.
final class ComposeVC: UIViewController, UITextViewDelegate {
    private let navTitle: String
    private let hint: String
    private let onSend: (String, @escaping (String?) -> Void) -> Void
    private let tv = UITextView()
    private let placeholder = UILabel()

    init(title: String, hint: String, onSend: @escaping (String, @escaping (String?) -> Void) -> Void) {
        self.navTitle = title
        self.hint = hint
        self.onSend = onSend
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = navTitle
        view.backgroundColor = .black
        tv.backgroundColor = .black
        tv.textColor = .white
        tv.font = .systemFont(ofSize: 16)
        tv.keyboardDismissMode = .interactive
        tv.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        tv.delegate = self
        view.addSubview(tv)
        placeholder.text = hint
        placeholder.textColor = Style.dim
        placeholder.font = .systemFont(ofSize: 16)
        view.addSubview(placeholder)
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Send", style: .done, target: self, action: #selector(send))
        NotificationCenter.default.addObserver(self, selector: #selector(kbd(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        tv.becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tv.frame = view.bounds
        placeholder.frame = CGRect(x: 17, y: 18, width: view.bounds.width - 34, height: 22)
    }

    func textViewDidChange(_ textView: UITextView) { placeholder.isHidden = !textView.text.isEmpty }

    @objc private func kbd(_ n: Notification) {
        guard let f = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let overlap = max(0, view.bounds.maxY - view.convert(f, from: nil).minY)
        tv.contentInset.bottom = overlap
        tv.verticalScrollIndicatorInsets.bottom = overlap
    }

    @objc private func cancel() { dismiss(animated: true) }

    @objc private func send() {
        let text = (tv.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        navigationItem.rightBarButtonItem?.isEnabled = false
        navigationItem.rightBarButtonItem?.title = "Sending…"
        onSend(text) { [weak self] err in
            guard let s = self else { return }
            if let err = err, !err.isEmpty {
                s.navigationItem.rightBarButtonItem?.isEnabled = true
                s.navigationItem.rightBarButtonItem?.title = "Send"
                let a = UIAlertController(title: "Couldn't post", message: err, preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "OK", style: .default))
                s.present(a, animated: true)
            } else {
                s.dismiss(animated: true)
            }
        }
    }
}

/// A plain composer for a new text post: subreddit, title, body.
final class SubmitVC: UIViewController, UITextViewDelegate {
    private let subField = UITextField()
    private let titleField = UITextField()
    private let bodyView = UITextView()
    private let bodyHint = UILabel()
    private let prefill: String

    init(sr: String = "") {
        prefill = sr
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "New post"
        view.backgroundColor = .black
        for f in [subField, titleField] {
            f.textColor = .white
            f.font = .systemFont(ofSize: 16)
            f.autocorrectionType = .no
            f.backgroundColor = UIColor(white: 0.1, alpha: 1)
            f.borderStyle = .roundedRect
            view.addSubview(f)
        }
        subField.placeholder = "subreddit (e.g. test)"
        subField.autocapitalizationType = .none
        subField.text = prefill
        titleField.placeholder = "Title"
        bodyView.backgroundColor = UIColor(white: 0.1, alpha: 1)
        bodyView.textColor = .white
        bodyView.font = .systemFont(ofSize: 16)
        bodyView.layer.cornerRadius = 6
        bodyView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        bodyView.delegate = self
        view.addSubview(bodyView)
        bodyHint.text = "Text (optional)"
        bodyHint.textColor = Style.dim
        bodyHint.font = .systemFont(ofSize: 16)
        bodyView.addSubview(bodyHint)
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Post", style: .done, target: self, action: #selector(submit))
        (prefill.isEmpty ? subField : titleField).becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = view.bounds.width - 24
        let top = view.safeAreaInsets.top + 12
        subField.frame = CGRect(x: 12, y: top, width: w, height: 40)
        titleField.frame = CGRect(x: 12, y: top + 48, width: w, height: 40)
        bodyView.frame = CGRect(x: 12, y: top + 96, width: w, height: 180)
        bodyHint.frame = CGRect(x: 12, y: 10, width: w - 20, height: 22)
    }

    func textViewDidChange(_ textView: UITextView) { bodyHint.isHidden = !textView.text.isEmpty }

    @objc private func cancel() { dismiss(animated: true) }

    @objc private func submit() {
        var sr = (subField.text ?? "").trimmingCharacters(in: .whitespaces)
        if sr.lowercased().hasPrefix("r/") { sr = String(sr.dropFirst(2)) }
        let ttl = (titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = bodyView.text ?? ""
        guard !sr.isEmpty, !ttl.isEmpty else {
            let a = UIAlertController(title: "Need a subreddit and a title", message: nil, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            present(a, animated: true)
            return
        }
        navigationItem.rightBarButtonItem?.isEnabled = false
        navigationItem.rightBarButtonItem?.title = "Posting…"
        Reddit.shared.submit(sr: sr, title: ttl, text: body) { [weak self] err in
            guard let s = self else { return }
            if err == nil {
                s.dismiss(animated: true)
            } else {
                s.navigationItem.rightBarButtonItem?.isEnabled = true
                s.navigationItem.rightBarButtonItem?.title = "Post"
                let a = UIAlertController(title: "Couldn't post", message: err, preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "OK", style: .default))
                s.present(a, animated: true)
            }
        }
    }
}

/// The view controller currently in front — used to show an alert from a nav-bar button.
func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let win = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? UIApplication.shared.windows.first
    var vc = win?.rootViewController
    while let presented = vc?.presentedViewController { vc = presented }
    return vc
}
