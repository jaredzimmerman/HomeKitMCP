import UIKit
import HomeKit
import Security
#if targetEnvironment(macCatalyst)
import ServiceManagement
#endif

/// HomeKit Bridge: a small Mac Catalyst app, signed with your own developer account, that holds
/// HomeKit access and serves it as an MCP server on 127.0.0.1:18767 (bearer token).
/// `tailscale serve` exposes it to the tailnet as port 8767; the VPS code connector forwards to that.
/// (Different local port on purpose: Network.framework cannot listen on a port `tailscale serve`
/// already holds on the tailnet addresses, so sharing 8767 broke whenever Tailscale started first.)
///
/// Menu-bar only: LSUIElement hides the Dock icon; MenuBarPlugin.bundle (native AppKit, loaded at
/// launch) draws the status item and menu, and keeps the launch scene's window invisible (HomeKit
/// refuses writes from an app with no foreground scene, so the window cannot simply be closed).
/// Start at login: SMAppService (LoginItem below).
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private let model = BridgeModel()
    private var menuBar: HKBMenuBar?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // mac/uninstall.sh runs the binary with this flag to take it out of Login Items.
        if CommandLine.arguments.contains("--remove-login-item") {
            LoginItem.remove()
            exit(0)
        }
        LoginItem.enableOnFirstInstalledLaunch()
        menuBar = MenuBarLoader.load()
        menuBar?.setup(logPath: BridgeConfig.actionLogPath,
                       loginEnabled: { LoginItem.isEnabled },
                       toggleLogin: { LoginItem.toggle() })
        model.onUpdate = { [weak self] in self?.pushMenu() }
        model.start()
        pushMenu()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = NoWindowSceneDelegate.self
        return config
    }

    private func pushMenu() {
        menuBar?.update(lines: model.menuLines, ok: model.isHealthy)
    }
}

/// Closes any window scene macOS opens (at launch or from state restoration) before it appears.
final class NoWindowSceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // Keep this scene: HomeKit only accepts writes while the app has a foreground scene.
        // MenuBarPlugin makes its window invisible and click-through instead of closing it;
        // lifting the size limits lets it shrink the window to 1x1.
        if let windowScene = scene as? UIWindowScene {
            windowScene.sizeRestrictions?.minimumSize = CGSize(width: 1, height: 1)
            windowScene.sizeRestrictions?.maximumSize = CGSize(width: 1, height: 1)
        }
    }
}

enum MenuBarLoader {
    static func load() -> HKBMenuBar? {
        #if targetEnvironment(macCatalyst)
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("MenuBarPlugin.bundle"),
              let bundle = Bundle(url: url), bundle.load(),
              let type = bundle.principalClass as? HKBMenuBar.Type else {
            NSLog("homekit-bridge: menu bar plugin did not load")
            return nil
        }
        return type.init()
        #else
        return nil
        #endif
    }
}

/// Start at login through SMAppService (Login Items in System Settings).
enum LoginItem {
    private static let configuredKey = "loginItemConfigured"

    static var isEnabled: Bool {
        #if targetEnvironment(macCatalyst)
        return SMAppService.mainApp.status == .enabled
        #else
        return false
        #endif
    }

    /// The first time the app runs from /Applications it adds itself to Login Items.
    /// After that only the menu toggle (or System Settings) changes it.
    static func enableOnFirstInstalledLaunch() {
        #if targetEnvironment(macCatalyst)
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: configuredKey) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: configuredKey)
        } catch {
            NSLog("homekit-bridge: could not add login item: \(error)")
        }
        #endif
    }

    static func remove() {
        #if targetEnvironment(macCatalyst)
        try? SMAppService.mainApp.unregister()
        UserDefaults.standard.removeObject(forKey: configuredKey)
        #endif
    }

    static func toggle() -> Bool {
        #if targetEnvironment(macCatalyst)
        do {
            if isEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            UserDefaults.standard.set(true, forKey: configuredKey)
        } catch {
            NSLog("homekit-bridge: login item change failed: \(error)")
        }
        #endif
        return isEnabled
    }
}

@MainActor
final class BridgeModel {
    private(set) var status = "Starting"
    private(set) var requests = 0
    private(set) var lastError: String?
    var onUpdate: (() -> Void)?

    let store = HomeStore()
    private var server: HTTPServer?
    private var started = false
    private var activity: NSObjectProtocol?

    func start() {
        guard !started else { return }
        started = true
        // Keep macOS from napping the app while it serves requests in the background.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Serving HomeKit to the VPS connector")
        store.onChange = { [weak self] in self?.onUpdate?() }
        do {
            let token = try TokenFile.loadOrCreate()
            let tools = ToolRouter(store: store)
            let rpc = MCPHandler(tools: tools)
            let server = HTTPServer(port: BridgeConfig.port, token: token) { [weak self] body in
                await MainActor.run {
                    self?.requests += 1
                    self?.onUpdate?()
                }
                return await rpc.handle(body: body)
            }
            // Report what the listener actually does, not just that start() returned.
            server.onState = { [weak self] listening, reason in
                Task { @MainActor in self?.listenerChanged(listening, reason) }
            }
            try server.start()
            self.server = server
            status = "Opening 127.0.0.1:\(BridgeConfig.port)"
        } catch {
            status = "Not running"
            lastError = "\(error)"
        }
        onUpdate?()
    }

    private func listenerChanged(_ listening: Bool, _ reason: String?) {
        if listening {
            status = "Listening on 127.0.0.1:\(BridgeConfig.port) (tailnet :\(BridgeConfig.tailnetPort))"
            lastError = nil
        } else {
            status = "Not listening (retrying)"
            lastError = reason
        }
        onUpdate?()
    }

    var isHealthy: Bool { server != nil && lastError == nil && store.authorizationText == "allowed" }

    var menuLines: [String] {
        let homes = store.manager.homes.map { $0.isPrimary ? "\($0.name) (primary)" : $0.name }
        let accessories = store.manager.homes.reduce(0) { $0 + $1.accessories.count }
        var lines = [status,
                     "HomeKit: \(store.authorizationText)",
                     homes.isEmpty ? "Homes: none yet" : "Homes: \(homes.joined(separator: ", "))",
                     "Accessories: \(accessories)",
                     "Requests served: \(requests)"]
        if let lastError { lines.append("Error: \(lastError)") }
        return lines
    }
}

enum BridgeConfig {
    static let port: UInt16 = 18767        // local listener
    static let tailnetPort: UInt16 = 8767  // what `tailscale serve` exposes and the VPS calls
    static let version = "1.1.0"
    static var actionLogPath: String {
        TokenFile.directory.replacingOccurrences(of: "/.config/homekit-bridge", with: "/Library/Logs/homekit-bridge")
            + "/actions.jsonl"
    }
}

enum TokenFile {
    static var directory: String {
        // Unsandboxed, so this is the real home folder.
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir) + "/.config/homekit-bridge"
        }
        return NSHomeDirectory() + "/.config/homekit-bridge"
    }
    static var path: String { directory + "/token" }

    static func loadOrCreate() throws -> String {
        let fm = FileManager.default
        if let existing = try? String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), existing.count >= 32 {
            return existing
        }
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BridgeError.message("could not generate a token")
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        fm.createFile(atPath: path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        return token
    }
}

enum BridgeError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let m): return m }
    }
}

