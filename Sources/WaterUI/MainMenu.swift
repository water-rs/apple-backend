// MainMenu.swift
// Provides a standard macOS application menu bar with Edit menu for keyboard shortcuts.
//
// Without a menu bar, keyboard shortcuts like ⌘C, ⌘V, ⌘X, ⌘A won't work because
// AppKit routes these through the Edit menu items in the responder chain.

#if os(macOS)
import AppKit

/// Creates and manages the standard macOS application menu bar.
@MainActor
public enum WaterUIMainMenu {
    /// Creates a complete main menu bar for the application.
    ///
    /// Includes:
    /// - App Menu: About, Preferences, Quit
    /// - Edit Menu: Undo, Redo, Cut, Copy, Paste, Select All
    /// - Window Menu: Minimize, Zoom, Bring All to Front
    ///
    /// Call this in your AppDelegate before `app.run()`:
    /// ```swift
    /// app.mainMenu = WaterUIMainMenu.create()
    /// ```
    public static func create() -> NSMenu {
        let mainMenu = NSMenu()
        
        // App menu
        mainMenu.addItem(createAppMenuItem())
        
        // Edit menu (required for keyboard shortcuts in text fields)
        mainMenu.addItem(createEditMenuItem())
        
        // Window menu
        mainMenu.addItem(createWindowMenuItem())
        
        return mainMenu
    }
    
    // MARK: - App Menu
    
    private static func createAppMenuItem() -> NSMenuItem {
        let menuItem = NSMenuItem()
        let submenu = NSMenu()
        
        // About
        let aboutItem = NSMenuItem(
            title: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        submenu.addItem(aboutItem)
        
        submenu.addItem(NSMenuItem.separator())
        
        // Preferences
        let prefsItem = NSMenuItem(
            title: "Preferences…",
            action: nil,
            keyEquivalent: ","
        )
        submenu.addItem(prefsItem)
        
        submenu.addItem(NSMenuItem.separator())
        
        // Services submenu
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp?.servicesMenu = servicesMenu
        submenu.addItem(servicesItem)
        
        submenu.addItem(NSMenuItem.separator())
        
        // Hide
        let hideItem = NSMenuItem(
            title: "Hide \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        submenu.addItem(hideItem)
        
        // Hide Others
        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        submenu.addItem(hideOthersItem)
        
        // Show All
        let showAllItem = NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        submenu.addItem(showAllItem)
        
        submenu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(
            title: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        submenu.addItem(quitItem)
        
        menuItem.submenu = submenu
        return menuItem
    }
    
    // MARK: - Edit Menu
    
    private static func createEditMenuItem() -> NSMenuItem {
        let menuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Edit")
        
        // Undo - uses nil target to route through responder chain
        let undoItem = NSMenuItem(
            title: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        submenu.addItem(undoItem)
        
        // Redo
        let redoItem = NSMenuItem(
            title: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        submenu.addItem(redoItem)
        
        submenu.addItem(NSMenuItem.separator())
        
        // Cut
        let cutItem = NSMenuItem(
            title: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        submenu.addItem(cutItem)
        
        // Copy
        let copyItem = NSMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        submenu.addItem(copyItem)
        
        // Paste
        let pasteItem = NSMenuItem(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        submenu.addItem(pasteItem)
        
        // Delete
        let deleteItem = NSMenuItem(
            title: "Delete",
            action: #selector(NSText.delete(_:)),
            keyEquivalent: ""
        )
        submenu.addItem(deleteItem)
        
        // Select All
        let selectAllItem = NSMenuItem(
            title: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        submenu.addItem(selectAllItem)
        
        menuItem.submenu = submenu
        return menuItem
    }
    
    // MARK: - Window Menu
    
    private static func createWindowMenuItem() -> NSMenuItem {
        let menuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Window")
        
        // Minimize
        let minimizeItem = NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.miniaturize(_:)),
            keyEquivalent: "m"
        )
        submenu.addItem(minimizeItem)
        
        // Zoom
        let zoomItem = NSMenuItem(
            title: "Zoom",
            action: #selector(NSWindow.zoom(_:)),
            keyEquivalent: ""
        )
        submenu.addItem(zoomItem)
        
        submenu.addItem(NSMenuItem.separator())
        
        // Bring All to Front
        let bringAllItem = NSMenuItem(
            title: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        submenu.addItem(bringAllItem)
        
        // Register as window menu for automatic window list
        NSApp?.windowsMenu = submenu
        
        menuItem.submenu = submenu
        return menuItem
    }
    
    // MARK: - Helpers
    
    /// What this application calls itself in its own menu.
    ///
    /// The display name comes first because that is the one an application
    /// chooses for people to read; `CFBundleName` is generated from the Xcode
    /// product name, which every WaterUI application shares. Reading it first
    /// is why they all announced themselves as the scaffold's target.
    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
    }
}
#endif
