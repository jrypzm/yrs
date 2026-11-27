// The two-column grid of pins. Each picture is fetched at the width of its column, and only
// the cells on screen hold pictures; more pins are fetched when you near the end.

import UIKit

/// Two columns; each pin goes under the shorter one.
final class Masonry: UICollectionViewLayout {
    var height: (Int, CGFloat) -> CGFloat = { _, w in w }
    /// A full-width band above the grid (the pin's own picture and details, on a pin screen).
    var headerHeight: CGFloat = 0
    private var frames: [CGRect] = []
    private var header: CGRect = .zero
    private var total: CGFloat = 0
    static let gap: CGFloat = 10

    override func prepare() {
        guard let cv = collectionView else { return }
        let n = cv.numberOfItems(inSection: 0)
        let g = Masonry.gap
        let w = floor((cv.bounds.width - g * 3) / 2)
        header = CGRect(x: 0, y: 0, width: cv.bounds.width, height: headerHeight)
        let top = headerHeight + (headerHeight > 0 ? g : 0)
        var col: [CGFloat] = [top + g, top + g]
        frames = (0 ..< n).map { i in
            let c = col[0] <= col[1] ? 0 : 1
            let h = height(i, w)
            let f = CGRect(x: g + CGFloat(c) * (w + g), y: col[c], width: w, height: h)
            col[c] += h + g
            return f
        }
        total = max(max(col[0], col[1]), top)
    }

    override var collectionViewContentSize: CGSize { CGSize(width: collectionView?.bounds.width ?? 0, height: total) }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var out = frames.enumerated().compactMap { i, f -> UICollectionViewLayoutAttributes? in
            guard f.intersects(rect) else { return nil }
            let a = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: 0))
            a.frame = f
            return a
        }
        if headerHeight > 0, header.intersects(rect), let h = layoutAttributesForSupplementaryView(ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: 0)) {
            out.append(h)
        }
        return out
    }

    override func layoutAttributesForItem(at ip: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard frames.indices.contains(ip.item) else { return nil }
        let a = UICollectionViewLayoutAttributes(forCellWith: ip)
        a.frame = frames[ip.item]
        return a
    }

    override func layoutAttributesForSupplementaryView(ofKind elementKind: String, at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard headerHeight > 0 else { return nil }
        let a = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: elementKind, with: indexPath)
        a.frame = header
        return a
    }

    override func shouldInvalidateLayout(forBoundsChange b: CGRect) -> Bool { b.width != collectionView?.bounds.width }
}

final class PinCell: UICollectionViewCell {
    let picture = UIImageView()
    private let play = UILabel()
    private var task: URLSessionDataTask?
    private var url: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.layer.cornerRadius = 16
        contentView.addSubview(picture)
        play.text = "▶"
        play.font = .systemFont(ofSize: 13)
        play.textColor = .white
        play.textAlignment = .center
        play.backgroundColor = UIColor(white: 0, alpha: 0.5)
        play.layer.cornerRadius = 13
        play.clipsToBounds = true
        play.isHidden = true
        picture.addSubview(play)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        picture.frame = contentView.bounds
        play.frame = CGRect(x: 8, y: contentView.bounds.height - 34, width: 26, height: 26)
    }

    func show(_ p: Pin, width: CGFloat) {
        task?.cancel()
        picture.image = nil
        picture.backgroundColor = p.color
        play.isHidden = !p.isVideo          // a ▶ marks video and idea-pin cells
        // grid thumbnails use Pinterest's small 236-wide picture: a quarter of the memory of the bigger
        // size and much faster. Falls back to an idea/video cover. The full picture loads when you open a pin.
        guard let (u, _) = p.gridImage("236x") else { return }
        url = u
        // the 236-wide source is already small; decode it at its own size (no shrinking, no upscaling)
        task = Images.load(u, px: 1024) { [weak self] img in
            guard let s = self, s.url == u else { return }
            s.picture.image = img
        }
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        task = nil
        url = nil
        picture.image = nil
        play.isHidden = true
    }
}

class GridVC: UICollectionViewController {
    typealias Fetch = (_ bookmark: String?, _ done: @escaping (Result<([Pin], String?), APIError>) -> Void) -> Void

    private let fetch: Fetch
    private var pins: [Pin] = []
    private var bookmark: String?
    private var more = true
    private var loading = false
    private var generation = 0
    /// Pages in a row that brought no pins; after a few, stop asking.
    private var empty = 0
    private let note = UILabel()
    private let layout = Masonry()
    /// An optional band above the grid (the pin's own picture and details). Its height is measured
    /// from its own contents for the current width.
    var headerView: (UIView & GridHeader)?

    init(_ title: String, fetch: @escaping Fetch) {
        self.fetch = fetch
        super.init(collectionViewLayout: layout)
        self.title = title
        navigationItem.backButtonDisplayMode = .minimal
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        layout.height = { [weak self] i, w in
            guard let p = self?.pins[i] else { return w }
            let ratio = min(max(p.gridImage("236x")?.1 ?? 1, 0.5), 2.2)
            return ceil(w * ratio)
        }
        collectionView.backgroundColor = .black
        collectionView.indicatorStyle = .white
        collectionView.alwaysBounceVertical = true
        collectionView.register(PinCell.self, forCellWithReuseIdentifier: "p")
        if headerView != nil {
            collectionView.register(HeaderHost.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "h")
        }
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
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    @objc func reload() {
        generation += 1
        bookmark = nil
        more = true
        loading = false
        empty = 0
        load(first: true)
    }

    private func load(first: Bool) {
        guard more, !loading else { return }
        loading = true
        if pins.isEmpty { note.text = "Loading…" }
        let gen = generation
        fetch(first ? nil : bookmark) { [weak self] r in
            guard let s = self, gen == s.generation else { return }
            s.loading = false
            s.collectionView.refreshControl?.endRefreshing()
            switch r {
            case .success(let (new, bm)):
                if first { s.pins = new } else { s.pins += new }
                s.empty = new.isEmpty ? s.empty + 1 : 0
                s.bookmark = bm
                s.more = bm != nil && s.empty < 3
                s.note.text = s.pins.isEmpty ? (s.more ? "Loading…" : "Nothing here.") : nil
                s.collectionView.reloadData()
                s.collectionView.layoutIfNeeded()
                s.fillScreen()
            case .failure(let e):
                if first { s.pins = []; s.collectionView.reloadData() }
                s.more = false
                s.note.text = s.pins.isEmpty ? e.description : nil
            }
        }
    }

    /// Pinterest's first page can be short: keep going until the screen is full.
    private func fillScreen() {
        if more, collectionView.contentSize.height < collectionView.bounds.height * 1.5 { load(first: false) }
    }

    override func scrollViewDidScroll(_ s: UIScrollView) {
        if s.contentOffset.y + s.bounds.height * 2 > s.contentSize.height { load(first: false) }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        guard let h = headerView, collectionView.bounds.width > 0 else { return }
        let want = h.height(for: collectionView.bounds.width)
        if abs(layout.headerHeight - want) > 0.5 {
            layout.headerHeight = want
            layout.invalidateLayout()
        }
    }

    override func collectionView(_ cv: UICollectionView, viewForSupplementaryElementOfKind kind: String, at ip: IndexPath) -> UICollectionReusableView {
        let v = cv.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "h", for: ip) as! HeaderHost
        if let h = headerView { v.host(h) }
        return v
    }

    override func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { pins.count }

    override func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let c = cv.dequeueReusableCell(withReuseIdentifier: "p", for: ip) as! PinCell
        c.show(pins[ip.item], width: layout.layoutAttributesForItem(at: ip)?.frame.width ?? 150)
        return c
    }

    override func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        navigationController?.pushViewController(PinVC(pins[ip.item]), animated: true)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        Images.forget()
    }
}

/// A header view for the grid knows how tall it needs to be at a given width.
protocol GridHeader: AnyObject {
    func height(for width: CGFloat) -> CGFloat
}

/// Holds the grid's header view and keeps it filling the header band.
final class HeaderHost: UICollectionReusableView {
    private weak var inner: UIView?

    func host(_ v: UIView) {
        guard inner !== v else { setNeedsLayout(); return }
        inner?.removeFromSuperview()
        addSubview(v)
        inner = v
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        inner?.frame = bounds
    }
}
