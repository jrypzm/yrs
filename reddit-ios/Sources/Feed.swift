// One list screen for everything: posts, subreddits, search results. Rows are text with a small
// picture when the post has one; more are fetched only when you scroll to the end.

import UIKit

struct Item {
    var title: String
    var detail: String = ""
    /// The screen this row opens.
    var open: (() -> UIViewController?)?
    /// Or something it does instead.
    var action: (() -> Void)?
    var dim = false
    /// A small picture shown at the left of the row.
    var thumb: URL? = nil
}

class Feed: UITableViewController {
    /// (rows, whether there are more pages)
    typealias Done = (Result<([Item], Bool), APIError>) -> Void
    /// (chosen tab, page, done)
    typealias Fetch = (_ choice: Int, _ page: Int, _ done: @escaping Done) -> Void

    var fetch: Fetch?
    private(set) var items: [Item] = []
    private var note: String?
    private var page = 1
    private var more = false
    private var loading = false
    private var generation = 0
    private let choices: [String]
    private(set) var choice = 0
    private var headLabel: UILabel?

    init(_ title: String, choices: [String] = [], fetch: Fetch? = nil) {
        self.choices = choices
        self.fetch = fetch
        super.init(style: .plain)
        self.title = title
        navigationItem.backButtonDisplayMode = .minimal
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .black
        tableView.indicatorStyle = .white
        tableView.separatorColor = UIColor(white: 0.17, alpha: 1)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        tableView.tableFooterView = UIView()
        tableView.register(Cell.self, forCellReuseIdentifier: "c")
        if choices.count > 1 {
            let seg = UISegmentedControl(items: choices)
            seg.selectedSegmentIndex = choice
            seg.addTarget(self, action: #selector(chose(_:)), for: .valueChanged)
            navigationItem.titleView = seg
        }
        if fetch != nil {
            let r = UIRefreshControl()
            r.tintColor = .gray
            r.addTarget(self, action: #selector(reload), for: .valueChanged)
            refreshControl = r
            reload()
        }
    }

    @objc private func chose(_ s: UISegmentedControl) {
        choice = s.selectedSegmentIndex
        items = []
        reload()
    }

    @objc func reload() {
        generation += 1
        page = 1
        more = false
        loading = false
        load()
    }

    private func load() {
        guard let fetch = fetch else { refreshControl?.endRefreshing(); return }
        loading = true
        if items.isEmpty { note = "Loading…"; tableView.reloadData() }
        let gen = generation, p = page, first = page == 1
        fetch(choice, p) { [weak self] r in
            guard let s = self, gen == s.generation else { return }
            s.loading = false
            s.refreshControl?.endRefreshing()
            switch r {
            case .success(let (new, more)):
                s.items = first ? new : s.items + new
                s.more = more
                s.note = s.items.isEmpty ? "Nothing here." : nil
            case .failure(let e):
                if first { s.items = [] }
                s.more = false
                s.note = e.description
            }
            s.tableView.reloadData()
        }
    }

    /// Fixed rows, for screens that don't page.
    func show(_ new: [Item], note: String? = nil) {
        items = new
        self.note = note
        tableView.reloadData()
    }

    // MARK: the text at the top

    func setHeader(_ t: NSAttributedString?) {
        guard let t = t else { tableView.tableHeaderView = nil; headLabel = nil; return }
        let l = headLabel ?? UILabel()
        l.numberOfLines = 0
        l.attributedText = t
        headLabel = l
        sizeHeader()
    }

    private func sizeHeader() {
        guard let l = headLabel else { return }
        let w = tableView.bounds.width - 32
        let h = ceil(l.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height)
        let box = tableView.tableHeaderView ?? UIView()
        if l.superview !== box { box.addSubview(l) }
        l.frame = CGRect(x: 16, y: 14, width: w, height: h)
        box.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: h + 26)
        tableView.tableHeaderView = box
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if headLabel != nil, abs((tableView.tableHeaderView?.frame.width ?? 0) - tableView.bounds.width) > 1 { sizeHeader() }
    }

    // MARK: rows

    private var showsNote: Bool { items.isEmpty && note != nil }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        showsNote ? 1 : items.count + (more ? 1 : 0)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let c = tableView.dequeueReusableCell(withIdentifier: "c", for: ip) as! Cell
        if showsNote {
            c.set(note ?? "", "", dim: true, tappable: false, thumb: nil)
        } else if ip.row >= items.count {
            c.set("Loading more…", "", dim: true, tappable: false, thumb: nil)
        } else {
            let it = items[ip.row]
            c.set(it.title, it.detail, dim: it.dim, tappable: it.open != nil || it.action != nil, thumb: it.thumb)
        }
        return c
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt ip: IndexPath) {
        if more, !loading, ip.row >= items.count - 8 {   // fetch the next page before you reach the end
            page += 1
            load()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt ip: IndexPath) {
        tableView.deselectRow(at: ip, animated: true)
        guard !showsNote, items.indices.contains(ip.row) else { return }
        let it = items[ip.row]
        if let a = it.action { a(); return }
        if let vc = it.open?() { navigationController?.pushViewController(vc, animated: true) }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // screens further back keep only what they show
        if view.window == nil, fetch != nil { items = []; more = false; tableView.reloadData() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if items.isEmpty, fetch != nil, !loading, note == nil || note == "Loading…" { reload() }
    }
}

final class Cell: UITableViewCell {
    override init(style: CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        backgroundColor = .black
        textLabel?.numberOfLines = 3
        textLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        detailTextLabel?.numberOfLines = 4
        detailTextLabel?.font = .systemFont(ofSize: 13)
        detailTextLabel?.textColor = Style.dim
        let bg = UIView()
        bg.backgroundColor = UIColor(white: 0.12, alpha: 1)
        selectedBackgroundView = bg
    }

    required init?(coder: NSCoder) { fatalError() }

    private var thumbURL: URL?
    private var task: URLSessionDataTask?
    static let thumbSide: CGFloat = 56
    private static let blank: UIImage = UIGraphicsImageRenderer(size: CGSize(width: Cell.thumbSide, height: Cell.thumbSide)).image { c in
        UIColor(white: 0.12, alpha: 1).setFill()
        c.fill(CGRect(x: 0, y: 0, width: Cell.thumbSide, height: Cell.thumbSide))
    }

    func set(_ title: String, _ detail: String, dim: Bool, tappable: Bool, thumb: URL?) {
        task?.cancel()
        task = nil
        thumbURL = thumb
        imageView?.layer.cornerRadius = 6
        imageView?.clipsToBounds = true
        if let u = thumb {
            imageView?.image = Cell.blank
            task = Images.thumb(u, side: Cell.thumbSide) { [weak self] img in
                guard let s = self, s.thumbURL == u, let img = img else { return }
                s.imageView?.image = img
            }
        } else {
            imageView?.image = nil
        }
        textLabel?.text = title
        textLabel?.textColor = dim ? Style.dim : .white
        textLabel?.font = dim ? .systemFont(ofSize: 15) : .systemFont(ofSize: 16, weight: .medium)
        detailTextLabel?.text = detail.isEmpty ? nil : detail
        selectionStyle = tappable ? .default : .none
        accessoryType = .none
    }
}
