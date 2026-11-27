// yrs. pins: Pinterest for iPhone, light. Native UIKit, no libraries, no ads, no tracking.
// Signed in, the main screen is your own home feed; signed out, it's search. Pictures are fetched
// at the size they're shown and let go of when you move on.

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = .black
        bar.shadowColor = .clear
        bar.titleTextAttributes = [.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 17, weight: .semibold)]
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar

        let w = UIWindow(frame: UIScreen.main.bounds)
        w.backgroundColor = .black
        w.overrideUserInterfaceStyle = .dark
        w.tintColor = .white
        w.rootViewController = Screen.root()
        w.makeKeyAndVisible()
        window = w
        // signing in or out swaps the whole root between the tab bar and the welcome screen
        NotificationCenter.default.addObserver(self, selector: #selector(accountChanged), name: Account.changed, object: nil)
        // the sign-in cookies may already be there from last time
        Account.refresh()
        Images.trimDisk()   // keep the on-disk picture cache within its size cap
        demo()
        return true
    }

    @objc private func accountChanged() {
        guard let w = window else { return }
        let root = Screen.root()
        UIView.transition(with: w, duration: 0.25, options: .transitionCrossDissolve) { w.rootViewController = root }
    }

    /// The navigation stack currently on screen (the selected tab, or the welcome stack).
    private func topNav() -> UINavigationController? {
        if let tabs = window?.rootViewController as? UITabBarController { return tabs.selectedViewController as? UINavigationController }
        return window?.rootViewController as? UINavigationController
    }

    /// Only for the screenshots taken with each build: `-demo search:cats` or `-demo pin:cats`.
    private func demo() {
        guard let d = UserDefaults.standard.string(forKey: "demo"), let colon = d.firstIndex(of: ":"), let nav = topNav() else { return }
        let kind = d[..<colon], arg = String(d[d.index(after: colon)...])
        switch kind {
        case "search": nav.pushViewController(Screen.search(arg), animated: false)
        case "pin":
            Pinterest.search(arg, bookmark: nil) { r in
                if case .success(let (pins, _)) = r, let p = pins.first(where: { !$0.title.isEmpty }) ?? pins.first {
                    nav.pushViewController(PinVC(p), animated: false)
                }
            }
        default: break
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Images.forget()
        malloc_zone_pressure_relief(nil, 0)
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) { Images.forget() }
}
