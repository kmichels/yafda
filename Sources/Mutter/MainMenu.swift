import AppKit

/// The main menu the custom `@main` entry point never installed. Cmd-Q is
/// not a system-level kill - it is an ordinary key equivalent dispatched
/// through this menu, and without it Cmd-Q (and every Edit-menu shortcut in
/// the app's own text fields, and Cmd-W) silently does nothing. The
/// accessory era masked that; the Cmd-Tab change (3c15a34) made the app
/// focusable and exposed it.
enum MainMenu {
    /// Pure builder so the self-test can inspect the result without a
    /// running application.
    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "About Mutter",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Hide Mutter", action: #selector(NSApplication.hide(_:)),
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
            title: "Quit Mutter", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

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

    /// Installs the menu on the running application. Called once from
    /// `applicationDidFinishLaunching`.
    @MainActor
    static func install() {
        let menu = build()
        NSApp.mainMenu = menu
        NSApp.windowsMenu = menu.items.last?.submenu
    }

    // MARK: - Self test

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

        return passed
    }
}
