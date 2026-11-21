// The screens: the home feed (main), welcome and sign-in, search, one pin, and pictures full screen.

import AVKit
import UIKit
import WebKit

// MARK: - home, search, welcome, sign-in

enum Screen {
    static func search(_ q: String) -> GridVC {
        let g = GridVC(q) { bm, done in Pinterest.search(q, bookmark: bm, done: done) }
        return g
    }

    /// The app's root, chosen by whether you're signed in: your home feed, or a welcome screen.
    static func root() -> UIViewController {
        Account.isSignedIn ? HomeFeedVC() : WelcomeVC()
    }
}

/// Signed in: your own Pinterest home feed, the main screen.
final class HomeFeedVC: GridVC {
    init() {
        super.init("Home") { bm, done in Pinterest.home(bookmark: bm, done: done) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .search, target: self, action: #selector(search))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Account", style: .plain, target: self, action: #selector(account))
    }

    @objc private func search() { navigationController?.pushViewController(SearchVC(), animated: true) }

    @objc private func account() {
        let a = UIAlertController(title: "Account", message: nil, preferredStyle: .actionSheet)
        a.addAction(UIAlertAction(title: "Sign out", style: .destructive) { _ in Account.signOut() })
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.popoverPresentationController?.barButtonItem = navigationItem.leftBarButtonItem
        present(a, animated: true)
    }
}

/// Signed out: a clean welcome with search and a sign-in button.
final class WelcomeVC: UIViewController, UISearchBarDelegate {
    private let bar = UISearchBar()
    private let title1 = UILabel()
    private let subtitle = UILabel()
    private let signIn = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationController?.setNavigationBarHidden(true, animated: false)
        view.backgroundColor = .black
        title1.text = "pins."
        title1.font = .systemFont(ofSize: 52, weight: .bold)
        title1.textColor = .white
        title1.textAlignment = .center
        subtitle.text = "Find ideas. Save what you love."
        subtitle.font = .systemFont(ofSize: 16)
        subtitle.textColor = Style.dim
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0
        bar.placeholder = "Search Pinterest"
        bar.searchBarStyle = .minimal
        bar.barStyle = .black
        bar.autocorrectionType = .no
        bar.delegate = self
        signIn.setTitle("Sign in", for: .normal)
        signIn.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        signIn.setTitleColor(.white, for: .normal)
        signIn.backgroundColor = Style.accent
        signIn.layer.cornerRadius = 27
        signIn.addTarget(self, action: #selector(tapSignIn), for: .touchUpInside)
        [title1, subtitle, bar, signIn].forEach { view.addSubview($0) }
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard)))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = view.bounds.width, cx = w / 2
        // the block sits a little above centre, which reads as more composed than dead-centre
        let mid = view.bounds.height * 0.34
        title1.frame = CGRect(x: 0, y: mid, width: w, height: 60)
        subtitle.frame = CGRect(x: 24, y: mid + 66, width: w - 48, height: 24)
        bar.frame = CGRect(x: 28, y: mid + 118, width: w - 56, height: 56)
        signIn.frame = CGRect(x: cx - 120, y: mid + 190, width: 240, height: 54)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    @objc private func dismissKeyboard() { bar.resignFirstResponder() }

    func searchBarSearchButtonClicked(_ b: UISearchBar) {
        let q = (b.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        b.resignFirstResponder()
        navigationController?.pushViewController(Screen.search(q), animated: true)
    }

    @objc private func tapSignIn() {
        let nav = UINavigationController(rootViewController: LoginVC())
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }
}

/// A plain search-bar screen, pushed from the home feed's magnifier.
final class SearchVC: UIViewController, UISearchBarDelegate {
    private let bar = UISearchBar()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Search"
        navigationItem.backButtonDisplayMode = .minimal
        view.backgroundColor = .black
        bar.placeholder = "Search Pinterest"
        bar.searchBarStyle = .minimal
        bar.barStyle = .black
        bar.autocorrectionType = .no
        bar.delegate = self
        view.addSubview(bar)
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard)))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        bar.becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        bar.frame = CGRect(x: 8, y: view.safeAreaInsets.top + 8, width: view.bounds.width - 16, height: 56)
    }

    @objc private func dismissKeyboard() { bar.resignFirstResponder() }

    func searchBarSearchButtonClicked(_ b: UISearchBar) {
        let q = (b.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        b.resignFirstResponder()
        navigationController?.pushViewController(Screen.search(q), animated: true)
    }
}

/// Pinterest's own sign-in page. Your password goes only to Pinterest; this app keeps no copy.
final class LoginVC: UIViewController, WKNavigationDelegate {
    private var web: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sign in to Pinterest"
        view.backgroundColor = .black
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()
        web = WKWebView(frame: view.bounds, configuration: c)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.navigationDelegate = self
        view.addSubview(web)
        web.load(URLRequest(url: URL(string: "https://www.pinterest.com/login/")!))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(done))
    }

    // after each page settles, check whether the login cookies are now set
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Account.refresh { [weak self] yes in if yes { self?.finish() } }
    }

    @objc private func cancel() { dismiss(animated: true) }

    @objc private func done() {
        Account.refresh { [weak self] yes in
            if yes { self?.finish() } else {
                let a = UIAlertController(title: "Not signed in yet", message: "Sign in on the page first, then tap Done.", preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(a, animated: true)
            }
        }
    }

    private func finish() {
        web.navigationDelegate = nil
        web = nil
        dismiss(animated: true)
    }
}

// MARK: - one pin

// MARK: - one pin

/// A pin: its picture and details sit in the header, and similar pins fill the grid below.
final class PinVC: GridVC {
    private let pin: Pin
    private let head: PinHeader

    init(_ p: Pin) {
        pin = p
        head = PinHeader(p)
        // similar pins come from a search of the pin's words
        let query = !p.title.isEmpty ? p.title : (!p.board.isEmpty ? p.board : p.about)
        super.init(p.user.isEmpty ? "Pin" : p.user) { bm, done in
            if query.trimmingCharacters(in: .whitespaces).isEmpty { done(.success(([], nil))); return }
            Pinterest.search(query, bookmark: bm) { r in
                // drop the pin itself if it comes back
                done(r.map { (pins, next) in (pins.filter { $0.id != p.id }, next) })
            }
        }
        headerView = head
        head.onPicture = { [weak self] in self?.openPicture() }
        head.onUser = { [weak self] in self?.openUser() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // a plain custom button, so no system background sits behind the dots
        let b = UIButton(type: .system)
        b.setTitle("⋯", for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 28, weight: .regular)
        b.tintColor = .white
        b.backgroundColor = .clear
        b.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        b.addTarget(self, action: #selector(menu), for: .touchUpInside)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: b)
    }

    /// The ⋯ menu: everything you can do with the pin, kept out of the way.
    @objc private func menu() {
        let a = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        a.addAction(UIAlertAction(title: "Save to Photos", style: .default) { [weak self] _ in self?.save() })
        if let l = pin.link {
            a.addAction(UIAlertAction(title: "Open link", style: .default) { _ in UIApplication.shared.open(l) })
        }
        a.addAction(UIAlertAction(title: "Open in Pinterest", style: .default) { [weak self] _ in if let u = self?.pin.page { UIApplication.shared.open(u) } })
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(a, animated: true)
    }

    private func openPicture() {
        if let v = pin.video { play(v); return }
        let imgs = pin.allImages()
        if !imgs.isEmpty { present(ViewerVC(imgs), animated: true) }
    }

    private func play(_ u: URL) {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        let p = AVPlayerViewController()
        p.player = AVPlayer(url: u)
        present(p, animated: true) { p.player?.play() }
    }

    private func openUser() {
        let name = pin.user
        guard !name.isEmpty else { return }
        navigationController?.pushViewController(GridVC("@" + name) { bm, done in Pinterest.user(name, bookmark: bm, done: done) }, animated: true)
    }

    /// The full-size picture goes to Photos; it's read, saved and let go of.
    private func save() {
        guard let (u, _) = pin.image("orig") ?? pin.image("736x") else { return }
        URLSession.shared.dataTask(with: u) { d, _, _ in
            let img = d.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async {
                guard let i = img else { self.tell("Couldn't fetch the picture."); return }
                UIImageWriteToSavedPhotosAlbum(i, self, #selector(self.saved(_:error:context:)), nil)
            }
        }.resume()
    }

    @objc private func saved(_ image: UIImage, error: Error?, context: UnsafeMutableRawPointer?) {
        tell(error == nil ? "Saved to Photos." : "Couldn't save: allow yrs. pins to add photos in Settings › Privacy › Photos.")
    }

    private func tell(_ t: String) {
        let a = UIAlertController(title: t, message: nil, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }
}

/// The picture and details shown above the similar-pins grid on a pin screen.
final class PinHeader: UIView, GridHeader {
    private let pin: Pin
    private let picture = UIImageView()
    private let badge = UILabel()
    private let count = UILabel()
    private let stack = UIStackView()
    private var shownPictureFor = -1

    var onPicture: (() -> Void)?
    var onUser: (() -> Void)?
    var onLink: (() -> Void)?
    var onSave: (() -> Void)?
    var onPinterest: (() -> Void)?

    init(_ p: Pin) {
        pin = p
        super.init(frame: .zero)
        picture.contentMode = .scaleAspectFit
        picture.backgroundColor = p.color
        picture.clipsToBounds = true
        picture.layer.cornerRadius = 20
        picture.isUserInteractionEnabled = true
        picture.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapPicture)))
        addSubview(picture)
        if p.video != nil {
            badge.text = "  ▶  "
            badge.font = .systemFont(ofSize: 18, weight: .bold)
            badge.textColor = .white
            badge.backgroundColor = UIColor(white: 0, alpha: 0.55)
            badge.textAlignment = .center
            badge.layer.cornerRadius = 22
            badge.clipsToBounds = true
            picture.addSubview(badge)
        }
        if p.isGallery {
            count.text = "  1 / \(p.slides.count)  "
            count.font = .systemFont(ofSize: 13, weight: .semibold)
            count.textColor = .white
            count.backgroundColor = UIColor(white: 0, alpha: 0.6)
            count.textAlignment = .center
            count.layer.cornerRadius = 13
            count.clipsToBounds = true
            picture.addSubview(count)
        }
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        addSubview(stack)

        // minimal: just the caption and who posted it. Everything else lives in the ⋯ menu up top.
        if !p.title.isEmpty { stack.addArrangedSubview(label(p.title, .systemFont(ofSize: 20, weight: .semibold), .white)) }
        if !p.user.isEmpty {
            let who = p.user.isEmpty ? p.userName : "@\(p.user)"
            stack.addArrangedSubview(textButton(who, #selector(tapUser), size: 14, color: Style.dim))
        }

        let more = label("More like this", .systemFont(ofSize: 18, weight: .bold), .white)
        stack.setCustomSpacing(22, after: stack.arrangedSubviews.last ?? more)
        stack.addArrangedSubview(more)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func label(_ t: String, _ f: UIFont, _ c: UIColor) -> UILabel {
        let l = UILabel(); l.text = t; l.font = f; l.textColor = c; l.numberOfLines = 0; return l
    }

    /// A plain left-aligned tappable line (the author).
    private func textButton(_ t: String, _ a: Selector, size: CGFloat, color: UIColor) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(t, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: size)
        b.titleLabel?.numberOfLines = 1
        b.contentHorizontalAlignment = .leading
        b.tintColor = color
        b.addTarget(self, action: a, for: .touchUpInside)
        return b
    }

    /// Unused now that actions moved to the ⋯ menu, kept harmless.
    private func pill(_ t: String, accent: Bool, _ a: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(t, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        b.setTitleColor(accent ? .white : Style.text, for: .normal)
        b.backgroundColor = accent ? Style.accent : Style.card
        b.layer.cornerRadius = 25
        b.heightAnchor.constraint(equalToConstant: 50).isActive = true
        b.addTarget(self, action: a, for: .touchUpInside)
        return b
    }

    private var ratio: CGFloat { min(max(pin.image("736x")?.1 ?? 1, 0.4), 2.0) }
    private func picHeight(_ w: CGFloat) -> CGFloat { ceil((w - 24) * ratio) }
    private func stackHeight(_ w: CGFloat) -> CGFloat {
        stack.systemLayoutSizeFitting(CGSize(width: w - 32, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
    }

    func height(for width: CGFloat) -> CGFloat {
        12 + picHeight(width) + 18 + stackHeight(width) + 18
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let ph = picHeight(w)
        picture.frame = CGRect(x: 12, y: 12, width: w - 24, height: ph)
        badge.frame = CGRect(x: (picture.bounds.width - 56) / 2, y: (ph - 56) / 2, width: 56, height: 56)
        count.sizeToFit()
        count.frame = CGRect(x: picture.bounds.width - count.bounds.width - 12, y: ph - 38, width: count.bounds.width, height: 26)
        stack.frame = CGRect(x: 16, y: 12 + ph + 18, width: w - 32, height: stackHeight(w))
        loadPicture(w)
    }

    private func loadPicture(_ w: CGFloat) {
        let px = (w - 24) * UIScreen.main.scale
        let key = Int(px)
        guard key != shownPictureFor, let (u, _) = pin.image(px > 500 ? "736x" : "474x") else { return }
        shownPictureFor = key
        Images.load(u, px: px) { [weak self] img in self?.picture.image = img }
    }

    @objc private func tapPicture() { onPicture?() }
    @objc private func tapUser() { onUser?() }
    @objc private func tapLink() { onLink?() }
    @objc private func tapSave() { onSave?() }
    @objc private func tapPinterest() { onPinterest?() }
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

