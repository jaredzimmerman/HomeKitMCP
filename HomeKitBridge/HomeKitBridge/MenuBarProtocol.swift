import Foundation

/// The contract between the Catalyst app and MenuBarPlugin.bundle (a native AppKit bundle the app
/// loads at launch, because Catalyst cannot create an NSStatusItem itself). This file is compiled
/// into both targets; the fixed Objective-C name makes the two copies the same runtime protocol.
@objc(HKBMenuBar)
public protocol HKBMenuBar: NSObjectProtocol {
    init()

    /// Called once at launch. `loginEnabled` reports whether the app starts at login,
    /// `toggleLogin` flips that and returns the new state. `logPath` is the activity log file.
    func setup(logPath: String, loginEnabled: @escaping () -> Bool, toggleLogin: @escaping () -> Bool)

    /// Status lines shown at the top of the menu. `ok` false switches the icon to a warning.
    func update(lines: [String], ok: Bool)
}
