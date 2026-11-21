// yrs. reddit: a read-only Reddit for iPhone. Native UIKit, no libraries, no ads, no tracking.
// Text first; pictures are fetched at the size they're shown and let go of when you move on.

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = .black
        bar.shadowColor = UIColor(white: 0.17, alpha: 1)
        bar.titleTextAttributes = [.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 17, weight: .semibold)]
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar

        // opens on Reddit's normal homepage (Popular); the ⋯ in the corner opens everything else
        let home = Lists.sub("popular")
        let nav = UINavigationController(rootViewController: home)
        home.navigationItem.rightBarButtonItem = MenuDots { [weak nav] in nav?.pushViewController(HomeVC(), animated: true) }
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.backgroundColor = .black
        w.overrideUserInterfaceStyle = .dark
        w.tintColor = .white
        w.rootViewController = nav
        w.makeKeyAndVisible()
        window = w
        demo(nav)
        return true
    }

    /// Only for the screenshots taken with each build: `-demo sub:pics` and the like.
    private func demo(_ nav: UINavigationController) {
        guard let d = UserDefaults.standard.string(forKey: "demo"), let colon = d.firstIndex(of: ":") else { return }
        let kind = d[..<colon], arg = String(d[d.index(after: colon)...])
        switch kind {
        case "sub": nav.pushViewController(Lists.sub(arg), animated: false)
        case "search": nav.pushViewController(Lists.search(arg), animated: false)
        case "first":
            // the first post with a picture in a subreddit
            Reddit.shared.get("/r/\(arg)/hot", ["limit": "15"]) { r in
                guard case .success(let j) = r else {
                    nav.pushViewController(Lists.sub(arg), animated: false)
                    return
                }
                let posts = ((j as? JSON)?.o("data").a("children") ?? []).map { Post(j: $0.o("data")) }
                let pick = posts.first { p in
                    if case .image = p.media(px: 640) { return !p.j.b("stickied") }
                    return false
                } ?? posts.first { !$0.j.b("stickied") }
                if let p = pick { nav.pushViewController(PostVC(p), animated: false) }
            }
        default: break
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // pictures are let go of; memory goes back to iOS
        Images.forget()
        malloc_zone_pressure_relief(nil, 0)
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        Images.forget()
    }
}
