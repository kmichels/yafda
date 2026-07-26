import AppKit

/// The main menu the custom `@main` entry point never installed. Cmd-Q is
/// not a system-level kill - it is an ordinary key equivalent dispatched
/// through this menu, and without it Cmd-Q (and every Edit-menu shortcut in
/// the app's own text fields, and Cmd-W) silently does nothing. The
/// accessory era masked that; the Cmd-Tab change (3c15a34) made the app
/// focusable and exposed it.
enum MainMenu {
    /// Retains the live controller for the app's lifetime - NSMenuItem.target
    /// is unretained, so nothing else would keep it alive between clicks.
    /// Self-test builds never touch this; each gets its own controller that
    /// is free to deallocate once the test's structural checks are done.
    @MainActor private static var liveUpdateController: UpdateMenuController?

    /// Pure builder so the self-test can inspect the result without a
    /// running application. `appDelegate` is nil for self-tests and for any
    /// caller that only wants the menu shape; the update-check items still
    /// build, they simply have nothing to act on.
    @MainActor
    static func build(appDelegate: AppDelegate? = nil) -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "About YAFDA",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""))
        appMenu.addItem(.separator())

        let updateController = UpdateMenuController()
        updateController.appDelegate = appDelegate
        let checkItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(UpdateMenuController.checkForUpdates), keyEquivalent: "")
        checkItem.target = updateController
        appMenu.addItem(checkItem)
        let updateItem = NSMenuItem(
            title: "Update available", action: #selector(UpdateMenuController.openUpdatePage),
            keyEquivalent: "")
        updateItem.target = updateController
        updateItem.isHidden = true
        appMenu.addItem(updateItem)
        updateController.checkItem = checkItem
        updateController.updateItem = updateItem
        appMenu.delegate = updateController
        appMenu.addItem(.separator())

        appMenu.addItem(NSMenuItem(
            title: "Hide YAFDA", action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"))
        let hideOthers = NSMenuItem(
            title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(
            title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Quit YAFDA", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        // Retained here unconditionally, not just for a live install: a
        // self-test build's controller must survive past this function
        // return too, since NSMenuItem.target is unretained and the
        // self-test inspects `target != nil` against the returned menu.
        liveUpdateController = updateController

        // Standard first-responder selectors with nil targets, so every text
        // field (Dictionary, scratchpad, History edit) gets the shortcuts a
        // Mac app is expected to have.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(
            title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(
            title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(
            title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(
            title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(
            title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(
            title: "Select All", action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"))
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        main.addItem(editItem)

        // Close keeps the app running (the window is the dashboard, not the
        // app) - performClose goes through the same path as the red button,
        // so the mic gate's close handling applies unchanged.
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(
            title: "Close", action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(
            title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"))
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        return main
    }

    // MARK: - Update check menu items

    /// Owns the live behavior behind "Check for Updates…"/"Update available".
    /// A plain NSObject rather than closures on the items themselves, because
    /// NSMenuItem target-action needs a real object, and refreshing the items
    /// each time the app menu opens needs an `NSMenuDelegate` - one object
    /// covers both.
    @MainActor
    final class UpdateMenuController: NSObject, NSMenuDelegate {
        weak var appDelegate: AppDelegate?
        weak var checkItem: NSMenuItem?
        weak var updateItem: NSMenuItem?

        /// Manual check: ignores the throttle entirely (an explicit click is
        /// its own consent), then settles on menu-item state only - no
        /// dialogs. A found update lights up the update item; otherwise the
        /// check item briefly reports "up to date" until the menu next opens.
        @objc func checkForUpdates() {
            guard let appDelegate, let checkItem else { return }
            // Flagged in plan review: a silent multi-second network round
            // trip reads as a broken menu item. "Checking…" is still
            // menu-item state, not a dialog, so it doesn't cross the
            // no-interruption line.
            checkItem.title = "Checking for Updates…"
            checkItem.isEnabled = false
            Task {
                defer { checkItem.isEnabled = true }
                if let result = await appDelegate.runUpdateCheck() {
                    updateItem?.title = "Update available — \(result.version)"
                    updateItem?.isHidden = false
                    checkItem.title = "Check for Updates…"
                } else {
                    let local = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                        as? String ?? "?"
                    checkItem.title = "You're up to date (\(local))"
                }
            }
        }

        @objc func openUpdatePage() {
            guard let url = appDelegate?.availableUpdate?.url else { return }
            NSWorkspace.shared.open(url)
        }

        /// Reverts the "up to date" retitle and refreshes the update item
        /// from current state every time the app menu opens - the cheapest
        /// way to keep a static-target menu honest without a Combine
        /// subscription living on a namespace enum.
        func menuWillOpen(_ menu: NSMenu) {
            checkItem?.title = "Check for Updates…"
            if let update = appDelegate?.availableUpdate {
                updateItem?.title = "Update available — \(update.version)"
                updateItem?.isHidden = false
            } else {
                updateItem?.isHidden = true
            }
        }
    }

    /// Installs the menu on the running application. Called once from
    /// `applicationDidFinishLaunching`.
    @MainActor
    static func install(appDelegate: AppDelegate) {
        let menu = build(appDelegate: appDelegate)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = menu.items.last?.submenu
    }

    // MARK: - Self test

    @MainActor
    static func runSelfTest() -> Bool {
        var passed = true
        let menu = build()
        let all = menu.items.compactMap(\.submenu).flatMap(\.items)

        func item(keyEquivalent: String, modifiers: NSEvent.ModifierFlags,
                  action: Selector?) -> NSMenuItem? {
            all.first {
                $0.keyEquivalent == keyEquivalent
                    && $0.keyEquivalentModifierMask == modifiers
                    && $0.action == action
            }
        }

        let quitOK = item(keyEquivalent: "q", modifiers: [.command],
                          action: #selector(NSApplication.terminate(_:)))?.target == nil
            && item(keyEquivalent: "q", modifiers: [.command],
                    action: #selector(NSApplication.terminate(_:))) != nil
        if !quitOK { passed = false }
        print("\(quitOK ? "PASS" : "FAIL"): main menu/Quit is Cmd-Q -> terminate(_:), " +
              "nil target")

        let pasteOK = item(keyEquivalent: "v", modifiers: [.command],
                           action: #selector(NSText.paste(_:))) != nil
        let selectAllOK = item(keyEquivalent: "a", modifiers: [.command],
                               action: #selector(NSText.selectAll(_:))) != nil
        let editOK = pasteOK && selectAllOK
        if !editOK { passed = false }
        print("\(editOK ? "PASS" : "FAIL"): main menu/Edit has Paste Cmd-V (\(pasteOK)) " +
              "and Select All Cmd-A (\(selectAllOK))")

        let closeOK = item(keyEquivalent: "w", modifiers: [.command],
                           action: #selector(NSWindow.performClose(_:))) != nil
        if !closeOK { passed = false }
        print("\(closeOK ? "PASS" : "FAIL"): main menu/Window has Close Cmd-W")

        let checkForUpdatesItem = all.first {
            $0.action == #selector(UpdateMenuController.checkForUpdates)
        }
        let updateAvailableItem = all.first {
            $0.action == #selector(UpdateMenuController.openUpdatePage)
        }
        let updateItemsOK = checkForUpdatesItem?.isEnabled == true
            && checkForUpdatesItem?.target != nil
            && updateAvailableItem?.isHidden == true
        if !updateItemsOK { passed = false }
        print("\(updateItemsOK ? "PASS" : "FAIL"): main menu/Check for Updates… is always " +
              "enabled, Update available starts hidden")

        return passed
    }
}
