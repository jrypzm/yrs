// The screens: the home feed (main), welcome and sign-in, search, one pin, and pictures full screen.

import AVKit
import Photos
import UIKit
import WebKit

// MARK: - home, search, welcome, sign-in

enum Screen {
    static func search(_ q: String) -> GridVC {
        GridVC(q) { bm, done in Pinterest.search(q, bookmark: bm, done: done) }
    }

    /// The app's root: signed in, a Pinterest-style tab bar (Home · Search · Boards · You); signed
    /// out, the welcome screen.
    static func root() -> UIViewController {
        Account.isSignedIn ? MainTabs() : UINavigationController(rootViewController: WelcomeVC())
    }
}

/// The bottom tab bar — Home · Search · Boards · You — each its own navigation stack.
final class MainTabs: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()
        viewControllers = [
            tab(HomeFeedVC(), "Home", "house.fill"),
            tab(SearchVC(), "Search", "magnifyingglass"),
            tab(BoardsVC(), "Boards", "square.grid.2x2.fill"),
            tab(ProfileVC(), "You", "person.crop.circle"),
        ]
        let a = UITabBarAppearance()
        a.configureWithOpaqueBackground()
        a.backgroundColor = .black
        tabBar.standardAppearance = a
        if #available(iOS 15.0, *) { tabBar.scrollEdgeAppearance = a }
        tabBar.tintColor = Style.accent
        tabBar.unselectedItemTintColor = Style.dim
    }

    private func tab(_ vc: UIViewController, _ title: String, _ icon: String) -> UINavigationController {
        vc.title = title
        let n = UINavigationController(rootViewController: vc)
        n.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: icon), tag: 0)
        return n
    }
}

/// Signed in: your own Pinterest home feed, the main screen.
final class HomeFeedVC: GridVC {
    init() {
        super.init("Home") { bm, done in Pinterest.home(bookmark: bm, done: done) }
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// The "You" tab: your own pins, with a Sign-out in the corner.
final class ProfileVC: GridVC {
    init() {
        super.init("You") { bm, done in Pinterest.myPins(bookmark: bm, done: done) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Account", style: .plain, target: self, action: #selector(account))
        Account.whoami { [weak self] name in if let n = name, !n.isEmpty { self?.title = "@" + n } }
    }

    @objc private func account() {
        let a = UIAlertController(title: "Account", message: nil, preferredStyle: .actionSheet)
        a.addAction(UIAlertAction(title: "Sign out", style: .destructive) { _ in Account.signOut() })
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
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
        // "More like this" is Pinterest's own related feed. If that comes back empty (e.g. a pin whose
        // id is one of the new search tokens Pinterest won't resolve) we fall back to a word search, so
        // it's never worse than before and genuinely right when related works.
        let query = !p.title.isEmpty ? p.title : (!p.board.isEmpty ? p.board : p.about)
        super.init(p.user.isEmpty ? "Pin" : p.user) { bm, done in
            PinVC.moreLikeThis(p, query: query, bookmark: bm, done: done)
        }
        headerView = head
        head.onPicture = { [weak self] in self?.openPicture() }
        head.onUser = { [weak self] in self?.openUser() }
    }

    /// Related pins for the grid. The source is tagged into the bookmark ("R:" related, "S:" search)
    /// so paging stays on whichever one answered; search is used only when related's first page is empty.
    private static func moreLikeThis(_ p: Pin, query: String, bookmark: String?, done: @escaping (Result<([Pin], String?), APIError>) -> Void) {
        func tag(_ list: [Pin], _ next: String?, _ t: String) -> ([Pin], String?) {
            (list.filter { $0.id != p.id }, next.map { t + $0 })
        }
        func search(_ bm: String?) {
            if query.trimmingCharacters(in: .whitespaces).isEmpty { done(.success(([], nil))); return }
            Pinterest.search(query, bookmark: bm) { r in done(r.map { tag($0.0, $0.1, "S:") }) }
        }
        if let bm = bookmark {
            if bm.hasPrefix("S:") { search(String(bm.dropFirst(2))) }
            else { Pinterest.related(pinID: p.id, bookmark: bm.hasPrefix("R:") ? String(bm.dropFirst(2)) : bm) { r in done(r.map { tag($0.0, $0.1, "R:") }) } }
            return
        }
        Pinterest.related(pinID: p.id, bookmark: nil) { r in
            if case .success(let (list, next)) = r, !list.filter({ $0.id != p.id }).isEmpty {
                done(.success(tag(list, next, "R:")))
            } else {
                search(nil)   // related had nothing (or errored) — fall back to a word search
            }
        }
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
        if Account.isSignedIn {
            a.addAction(UIAlertAction(title: "Save to board", style: .default) { [weak self] _ in self?.pickBoardAndSave() })
        }
        a.addAction(UIAlertAction(title: pin.isVideo ? "Save video to Photos" : "Save to Photos", style: .default) { [weak self] _ in self?.save() })
        if let l = pin.link {
            a.addAction(UIAlertAction(title: "Open link", style: .default) { _ in UIApplication.shared.open(l) })
        }
        a.addAction(UIAlertAction(title: "Open in Pinterest", style: .default) { [weak self] _ in if let u = self?.pin.page { UIApplication.shared.open(u) } })
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(a, animated: true)
    }

    /// Pick one of your boards, then repin onto it.
    private func pickBoardAndSave() {
        let picker = BoardPickerVC { [weak self] board in
            guard let self = self, let board = board else { return }
            Pinterest.save(pinID: self.pin.id, boardID: board.id) { [weak self] err in
                self?.tell(err == nil ? "Saved to \(board.name)." : "Couldn't save — \(err!)")
            }
        }
        present(UINavigationController(rootViewController: picker), animated: true)
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

    private var dlObs: NSKeyValueObservation?

    /// Save to Photos: a video pin saves the actual video (720p MP4), a photo pin saves the
    /// full-resolution original. Video is detected by the video_list, not the unreliable is_video flag.
    private func save() {
        if pin.isVideo { saveVideo(); return }
        var candidates = pin.saveCandidates
        guard !candidates.isEmpty else { tell("No picture to save."); return }
        func attempt() {
            guard !candidates.isEmpty else { tell("Couldn't fetch the picture."); return }
            let u = candidates.removeFirst()
            URLSession.shared.dataTask(with: u) { [weak self] d, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let d = d, !d.isEmpty, (200 ..< 300).contains(code) { self.writeToPhotos(d) } else { attempt() }
                }
            }.resume()
        }
        attempt()
    }

    private func writeToPhotos(_ data: Data) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self?.tell("Allow yrs. pins to add photos in Settings › Privacy › Photos.") }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            } completionHandler: { ok, err in
                DispatchQueue.main.async { self?.tell(ok ? "Saved to Photos — full quality." : "Couldn't save: \(err?.localizedDescription ?? "try again").") }
            }
        }
    }

    /// Downloads the video's MP4 and saves it to Photos as a video (not the thumbnail). Pinterest's
    /// MP4 is a clean 720p copy, so this is one download with no conversion. HLS-only pins can't be saved.
    private func saveVideo() {
        if let u = pin.videoFile { downloadVideoFile(u); return }     // direct MP4 — fast path
        if let hls = pin.hlsURL { assembleHLS(hls); return }          // streaming-only — build an MP4 from HLS
        tell("This one can't be saved. Tap the picture to watch it, or open it in Pinterest.")
    }

    /// Streaming-only pins: assemble the HLS stream's fragments into one lossless MP4, then save it.
    private func assembleHLS(_ hls: URL) {
        let progress = UIAlertController(title: "Saving video", message: "Preparing… 0%", preferredStyle: .alert)
        progress.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(progress, animated: true)
        HLSVideo.assemble(hls, progress: { [weak progress] (frac: Double) in
            progress?.message = "Downloading… \(Int(frac * 100))%"
        }, done: { [weak self] (file: URL?, code: String?) in
            guard let self = self, self.presentedViewController === progress else { return }   // cancelled
            progress.dismiss(animated: true) {
                if let file = file {
                    if self.looksLikeVideo(file) { self.writeVideoToPhotos(file) }
                    else { try? FileManager.default.removeItem(at: file); self.tell("Couldn't assemble the video. Try opening it in Pinterest.") }
                } else if code == "ts" {
                    self.tell("This video uses an older streaming format I can't rebuild on the phone. Tap the picture to watch it, or open it in Pinterest.")
                } else {
                    self.tell("Couldn't download the video — try again, or open it in Pinterest.")
                }
            }
        })
    }

    /// A pin that has a direct MP4: download it and save (one file, fastest).
    private func downloadVideoFile(_ u: URL) {
        let progress = UIAlertController(title: "Saving video", message: "Downloading… 0%", preferredStyle: .alert)
        progress.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.dlObs = nil })
        present(progress, animated: true)
        let task = URLSession.shared.downloadTask(with: u) { [weak self] tmp, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.dlObs = nil
                guard self.presentedViewController === progress else { return }   // cancelled or dismissed
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
                progress.dismiss(animated: true) {
                    guard let tmp = tmp, err == nil, (200 ..< 300).contains(code) else {
                        self.tell("Couldn't download the video — \(err?.localizedDescription ?? "try again, or open it in Pinterest").")
                        return
                    }
                    guard self.looksLikeVideo(tmp) || type.contains("video") else {
                        self.tell("That didn't come back as a video. Try opening it in Pinterest.")
                        return
                    }
                    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("yrs-\(UUID().uuidString).mp4")
                    try? FileManager.default.removeItem(at: dest)
                    do { try FileManager.default.moveItem(at: tmp, to: dest) } catch { self.tell("Couldn't save the video."); return }
                    self.writeVideoToPhotos(dest)
                }
            }
        }
        dlObs = task.progress.observe(\.fractionCompleted) { p, _ in
            DispatchQueue.main.async { progress.message = "Downloading… \(Int(p.fractionCompleted * 100))%" }
        }
        task.resume()
    }

    private func writeVideoToPhotos(_ file: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: file)
                DispatchQueue.main.async { self?.tell("Allow yrs. pins to add to Photos in Settings › Privacy › Photos.") }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: nil)
            } completionHandler: { ok, err in
                try? FileManager.default.removeItem(at: file)
                DispatchQueue.main.async { self?.tell(ok ? "Video saved to Photos." : "Couldn't save: \(err?.localizedDescription ?? "try again").") }
            }
        }
    }

    /// A quick check that the download is really an MP4/MOV (an 'ftyp' box near the start), so we never
    /// hand Photos a stray HTML error page or playlist.
    private func looksLikeVideo(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let b = [UInt8](h.readData(ofLength: 12))
        guard b.count >= 8 else { return false }
        return b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70   // "ftyp"
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

    private var ratio: CGFloat { min(max(pin.gridImage("736x")?.1 ?? 1, 0.4), 2.0) }
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
        guard key != shownPictureFor, let (u, _) = pin.gridImage(px > 500 ? "736x" : "474x") else { return }
        shownPictureFor = key
        Images.load(u, px: px) { [weak self] img in self?.picture.image = img }
    }

    @objc private func tapPicture() { onPicture?() }
    @objc private func tapUser() { onUser?() }
    @objc private func tapLink() { onLink?() }
    @objc private func tapSave() { onSave?() }
    @objc private func tapPinterest() { onPinterest?() }
}

// MARK: - boards

/// The "Boards" tab: a two-column grid of your boards, each a cover with its name and pin count.
final class BoardsVC: UICollectionViewController, UICollectionViewDelegateFlowLayout {
    private var boards: [Board] = []
    private var bookmark: String?
    private var more = true
    private var loading = false
    private var generation = 0
    private let note = UILabel()

    init() {
        let l = UICollectionViewFlowLayout()
        l.minimumInteritemSpacing = 10
        l.minimumLineSpacing = 16
        l.sectionInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        super.init(collectionViewLayout: l)
        title = "Boards"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .black
        collectionView.indicatorStyle = .white
        collectionView.alwaysBounceVertical = true
        collectionView.register(BoardCard.self, forCellWithReuseIdentifier: "b")
        note.textColor = Style.dim
        note.font = .systemFont(ofSize: 15)
        note.numberOfLines = 0
        note.textAlignment = .center
        collectionView.backgroundView = note
        let r = UIRefreshControl()
        r.tintColor = .gray
        r.addTarget(self, action: #selector(reload), for: .valueChanged)
        collectionView.refreshControl = r
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if boards.isEmpty, !loading { reload() }
    }

    @objc private func reload() {
        generation += 1
        bookmark = nil
        more = true
        loading = false
        load(first: true)
    }

    private func load(first: Bool) {
        guard more, !loading else { return }
        loading = true
        if boards.isEmpty { note.text = "Loading…" }
        let gen = generation
        Pinterest.boards(bookmark: first ? nil : bookmark) { [weak self] r in
            guard let s = self, gen == s.generation else { return }
            s.loading = false
            s.collectionView.refreshControl?.endRefreshing()
            switch r {
            case .success(let (bs, bm)):
                if first { s.boards = bs } else { s.boards += bs }
                s.bookmark = bm
                s.more = bm != nil && !bs.isEmpty
                s.note.text = s.boards.isEmpty ? "No boards yet." : nil
                s.collectionView.reloadData()
            case .failure(let e):
                if first { s.boards = []; s.collectionView.reloadData() }
                s.more = false
                s.note.text = s.boards.isEmpty ? e.description : nil
            }
        }
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt ip: IndexPath) -> CGSize {
        let w = floor((cv.bounds.width - 12 * 2 - 10) / 2)
        return CGSize(width: w, height: w + 46)   // square cover + name + count
    }

    override func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { boards.count }

    override func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let c = cv.dequeueReusableCell(withReuseIdentifier: "b", for: ip) as! BoardCard
        c.show(boards[ip.item])
        return c
    }

    override func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt ip: IndexPath) {
        if more, !loading, ip.item >= boards.count - 4 { load(first: false) }
    }

    override func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        let b = boards[ip.item]
        navigationController?.pushViewController(GridVC(b.name) { bm, done in Pinterest.boardFeed(boardID: b.id, bookmark: bm, done: done) }, animated: true)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        Images.forget()
    }
}

/// One board: a rounded cover picture with its name and pin count underneath.
final class BoardCard: UICollectionViewCell {
    private let cover = UIImageView()
    private let name = UILabel()
    private let count = UILabel()
    private var url: URL?
    private var task: URLSessionDataTask?

    override init(frame: CGRect) {
        super.init(frame: frame)
        cover.contentMode = .scaleAspectFill
        cover.clipsToBounds = true
        cover.layer.cornerRadius = 16
        cover.backgroundColor = Style.card
        contentView.addSubview(cover)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.textColor = .white
        name.numberOfLines = 1
        count.font = .systemFont(ofSize: 12)
        count.textColor = Style.dim
        contentView.addSubview(name)
        contentView.addSubview(count)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = contentView.bounds.width
        cover.frame = CGRect(x: 0, y: 0, width: w, height: w)
        name.frame = CGRect(x: 2, y: w + 5, width: w - 4, height: 18)
        count.frame = CGRect(x: 2, y: w + 24, width: w - 4, height: 16)
    }

    func show(_ b: Board) {
        task?.cancel()
        cover.image = nil
        name.text = (b.isSecret ? "🔒 " : "") + b.name
        count.text = b.pinCount == 1 ? "1 pin" : "\(b.pinCount) pins"
        guard let u = b.cover else { url = nil; return }
        url = u
        task = Images.thumb(u, side: 220) { [weak self] img in
            guard let s = self, s.url == u else { return }
            s.cover.image = img
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        task = nil
        url = nil
        cover.image = nil
    }
}

/// A modal list of your boards for choosing where to save a pin.
final class BoardPickerVC: UITableViewController {
    private var boards: [Board] = []
    private var note = "Loading…"
    private let onPick: (Board?) -> Void

    init(onPick: @escaping (Board?) -> Void) {
        self.onPick = onPick
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Save to…"
        view.backgroundColor = .black
        tableView.backgroundColor = .black
        tableView.separatorColor = Style.faint
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "b")
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        load()
    }

    private func load() {
        Pinterest.boards(bookmark: nil) { [weak self] r in
            guard let s = self else { return }
            switch r {
            case .success(let (bs, _)): s.boards = bs; s.note = bs.isEmpty ? "No boards yet. Make one in Pinterest first." : ""
            case .failure(let e): s.note = e.description
            }
            s.tableView.reloadData()
        }
    }

    @objc private func cancel() { onPick(nil); dismiss(animated: true) }

    override func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { boards.isEmpty ? 1 : boards.count }

    override func tableView(_ t: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let c = t.dequeueReusableCell(withIdentifier: "b", for: ip)
        c.backgroundColor = .black
        var cfg = c.defaultContentConfiguration()
        if boards.isEmpty {
            cfg.text = note
            cfg.textProperties.color = Style.dim
            c.selectionStyle = .none
        } else {
            let b = boards[ip.item]
            cfg.text = (b.isSecret ? "🔒 " : "") + b.name
            cfg.secondaryText = b.pinCount == 1 ? "1 pin" : "\(b.pinCount) pins"
            cfg.textProperties.color = .white
            cfg.secondaryTextProperties.color = Style.dim
            c.selectionStyle = .default
        }
        c.contentConfiguration = cfg
        return c
    }

    override func tableView(_ t: UITableView, didSelectRowAt ip: IndexPath) {
        t.deselectRow(at: ip, animated: true)
        guard boards.indices.contains(ip.item) else { return }
        let b = boards[ip.item]
        onPick(b)
        dismiss(animated: true)
    }
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

