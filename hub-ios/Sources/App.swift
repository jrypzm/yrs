// hub: a GitHub client for iPhone. Native UIKit, no libraries, text only: no pictures,
// no web view, nothing cached; each screen keeps only what it shows.

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

        let nav = UINavigationController(rootViewController: SearchHomeVC())
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

    /// Only for the screenshots taken with each build: `-demo repo:owner/name` and the like.
    private func demo(_ nav: UINavigationController) {
        guard let d = UserDefaults.standard.string(forKey: "demo"), let colon = d.firstIndex(of: ":") else { return }
        let kind = d[..<colon], arg = String(d[d.index(after: colon)...])
        var vc: UIViewController?
        switch kind {
        case "search": vc = searchResults(arg)
        case "repo": vc = RepoVC(arg)
        case "readme": vc = Screens.readme(arg, ref: "")
        case "code": vc = Screens.files(arg, "", ref: "")
        case "commit":
            let p = arg.split(separator: "@")
            if p.count == 2 { vc = Screens.commit(String(p[0]), String(p[1])) }
        default: break
        }
        if let v = vc { nav.pushViewController(v, animated: false) }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // give memory freed by closed screens back to iOS
        malloc_zone_pressure_relief(nil, 0)
    }
}
