import SwiftUI
import UIKit

/// SwiftUI doesn't always reliably remove the UISplitViewController sidebar toggle button on Mac Catalyst.
/// This helper finds the nearest split view controller and disables the display mode button.
struct SidebarToggleHider: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        Controller()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        (uiViewController as? Controller)?.apply()
    }

    final class Controller: UIViewController {
        private var timer: Timer?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
            startTimerIfNeeded()
        }

        override func viewWillLayoutSubviews() {
            super.viewWillLayoutSubviews()
            apply()
        }

        deinit {
            timer?.invalidate()
        }

        func apply() {
            guard let root = view.window?.rootViewController else { return }
            for svc in findSplitViewControllers(in: root) {
                if #available(iOS 14.0, *) {
                    svc.displayModeButtonVisibility = .never
                }
                svc.presentsWithGesture = false
                svc.preferredDisplayMode = .oneBesideSecondary
            }
            // SwiftUI may inject a sidebar toggle as a left bar button item in the
            // detail navigation controller. Clear it on all visible navigation stacks.
            for nav in findNavigationControllers(in: root) {
                guard let top = nav.topViewController else { continue }
                top.navigationItem.leftItemsSupplementBackButton = false

                // Keep back button, remove only sidebar toggle items.
                let toggleSelectors: Set<Selector> = [
                    NSSelectorFromString("toggleSidebar:"),
                    NSSelectorFromString("togglePrimaryVisibility:"),
                ]
                if let item = top.navigationItem.leftBarButtonItem,
                   let action = item.action,
                   toggleSelectors.contains(action) {
                    top.navigationItem.leftBarButtonItem = nil
                }
                if let items = top.navigationItem.leftBarButtonItems, !items.isEmpty {
                    let filtered = items.filter { item in
                        guard let action = item.action else { return true }
                        return !toggleSelectors.contains(action)
                    }
                    top.navigationItem.leftBarButtonItems = filtered.isEmpty ? nil : filtered
                }
            }

            #if targetEnvironment(macCatalyst)
            // On Mac Catalyst, the button can be an NSToolbar item on the window scene titlebar.
            if let scene = view.window?.windowScene,
               let titlebar = scene.titlebar,
               let toolbar = titlebar.toolbar {
                removeToolbarItems(toolbar, identifiers: [
                    .toggleSidebar,
                ])
            }
            #endif
        }

        private func startTimerIfNeeded() {
            // SwiftUI/NavigationSplitView can re-insert the button after layout,
            // so re-apply for a short period after appearing.
            if timer != nil { return }
            var remaining = 20 // ~4s @ 0.2s
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                self.apply()
                remaining -= 1
                if remaining <= 0 {
                    t.invalidate()
                    self.timer = nil
                }
            }
        }

        #if targetEnvironment(macCatalyst)
        private func removeToolbarItems(_ toolbar: NSToolbar, identifiers: [NSToolbarItem.Identifier]) {
            // NSToolbar doesn't expose a mutable items array, but supports removeItem(at:).
            for idx in toolbar.items.indices.reversed() {
                let item = toolbar.items[idx]
                if identifiers.contains(item.itemIdentifier) {
                    toolbar.removeItem(at: idx)
                }
            }
        }
        #endif

        private func findSplitViewControllers(in vc: UIViewController) -> [UISplitViewController] {
            var out: [UISplitViewController] = []
            if let svc = vc as? UISplitViewController {
                out.append(svc)
            }
            for child in vc.children {
                out.append(contentsOf: findSplitViewControllers(in: child))
            }
            if let presented = vc.presentedViewController {
                out.append(contentsOf: findSplitViewControllers(in: presented))
            }
            return out
        }

        private func findNavigationControllers(in vc: UIViewController) -> [UINavigationController] {
            var out: [UINavigationController] = []
            if let nav = vc as? UINavigationController {
                out.append(nav)
            }
            for child in vc.children {
                out.append(contentsOf: findNavigationControllers(in: child))
            }
            if let presented = vc.presentedViewController {
                out.append(contentsOf: findNavigationControllers(in: presented))
            }
            return out
        }
    }
}
