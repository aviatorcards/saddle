import Foundation
import Observation
import ServiceManagement

/// Persisted user preferences and defaults for Saddle.
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    enum Keys {
        static let openInFinderOnMount = "openInFinderOnMount"
        static let notifyOnConnectionError = "notifyOnConnectionError"
        static let notifyOnMount = "notifyOnMount"
        static let notifyOnDisconnect = "notifyOnDisconnect"
        static let defaultParallelTransfers = "defaultParallelTransfers"
        static let defaultRefreshInterval = "defaultRefreshInterval"
        static let defaultShowHiddenFiles = "defaultShowHiddenFiles"
        static let defaultKeepAllDownloaded = "defaultKeepAllDownloaded"
        static let prefetchEnabled = "prefetchEnabled"
        static let prefetchMaxFileMB = "prefetchMaxFileMB"
        static let prefetchMaxFolderMB = "prefetchMaxFolderMB"
        static let defaultRemotePath = "defaultRemotePath"
        static let defaultPort = "defaultPort"
        static let defaultUsername = "defaultUsername"
    }

    var openInFinderOnMount: Bool {
        didSet { defaults.set(openInFinderOnMount, forKey: Keys.openInFinderOnMount) }
    }

    var notifyOnConnectionError: Bool {
        didSet { defaults.set(notifyOnConnectionError, forKey: Keys.notifyOnConnectionError) }
    }

    var notifyOnMount: Bool {
        didSet { defaults.set(notifyOnMount, forKey: Keys.notifyOnMount) }
    }

    var notifyOnDisconnect: Bool {
        didSet { defaults.set(notifyOnDisconnect, forKey: Keys.notifyOnDisconnect) }
    }

    var defaultParallelTransfers: Int {
        didSet { defaults.set(defaultParallelTransfers, forKey: Keys.defaultParallelTransfers) }
    }

    var defaultRefreshInterval: TimeInterval {
        didSet { defaults.set(defaultRefreshInterval, forKey: Keys.defaultRefreshInterval) }
    }

    var defaultShowHiddenFiles: Bool {
        didSet { defaults.set(defaultShowHiddenFiles, forKey: Keys.defaultShowHiddenFiles) }
    }

    var defaultKeepAllDownloaded: Bool {
        didSet { defaults.set(defaultKeepAllDownloaded, forKey: Keys.defaultKeepAllDownloaded) }
    }

    var prefetchEnabled: Bool {
        didSet { defaults.set(prefetchEnabled, forKey: Keys.prefetchEnabled); writeTuning() }
    }

    var prefetchMaxFileMB: Int {
        didSet { defaults.set(prefetchMaxFileMB, forKey: Keys.prefetchMaxFileMB); writeTuning() }
    }

    var prefetchMaxFolderMB: Int {
        didSet { defaults.set(prefetchMaxFolderMB, forKey: Keys.prefetchMaxFolderMB); writeTuning() }
    }

    private let writesTuning: Bool

    var defaultRemotePath: String {
        didSet { defaults.set(defaultRemotePath, forKey: Keys.defaultRemotePath) }
    }

    var defaultPort: Int {
        didSet { defaults.set(defaultPort, forKey: Keys.defaultPort) }
    }

    var defaultUsername: String {
        didSet { defaults.set(defaultUsername, forKey: Keys.defaultUsername) }
    }

    private(set) var launchAtLoginStatus: SMAppService.Status = .notRegistered

    var isLaunchAtLoginEnabled: Bool {
        get {
            launchAtLoginStatus == .enabled
        }
        set {
            setLaunchAtLogin(newValue)
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        self.writesTuning = userDefaults == .standard

        // Register default values
        userDefaults.register(defaults: [
            Keys.openInFinderOnMount: true,
            Keys.notifyOnConnectionError: true,
            Keys.notifyOnMount: false,
            Keys.notifyOnDisconnect: false,
            Keys.defaultParallelTransfers: 3,
            Keys.defaultRefreshInterval: 60.0,
            Keys.defaultShowHiddenFiles: true,
            Keys.defaultKeepAllDownloaded: false,
            Keys.prefetchEnabled: true,
            Keys.prefetchMaxFileMB: 5,
            Keys.prefetchMaxFolderMB: 50,
            Keys.defaultRemotePath: "",
            Keys.defaultPort: 22,
            Keys.defaultUsername: NSUserName(),
        ])

        self.openInFinderOnMount = userDefaults.bool(forKey: Keys.openInFinderOnMount)
        self.notifyOnConnectionError = userDefaults.bool(forKey: Keys.notifyOnConnectionError)
        self.notifyOnMount = userDefaults.bool(forKey: Keys.notifyOnMount)
        self.notifyOnDisconnect = userDefaults.bool(forKey: Keys.notifyOnDisconnect)

        let transfers = userDefaults.integer(forKey: Keys.defaultParallelTransfers)
        self.defaultParallelTransfers = (1...8).contains(transfers) ? transfers : 3

        let interval = userDefaults.double(forKey: Keys.defaultRefreshInterval)
        self.defaultRefreshInterval = interval >= 15 ? interval : 60

        self.defaultShowHiddenFiles = userDefaults.bool(forKey: Keys.defaultShowHiddenFiles)
        self.defaultKeepAllDownloaded = userDefaults.bool(forKey: Keys.defaultKeepAllDownloaded)
        self.prefetchEnabled = userDefaults.object(forKey: Keys.prefetchEnabled) as? Bool ?? true
        let fileMB = userDefaults.integer(forKey: Keys.prefetchMaxFileMB)
        self.prefetchMaxFileMB = (1...512).contains(fileMB) ? fileMB : 5
        let folderMB = userDefaults.integer(forKey: Keys.prefetchMaxFolderMB)
        self.prefetchMaxFolderMB = (1...2048).contains(folderMB) ? folderMB : 50
        self.defaultRemotePath = userDefaults.string(forKey: Keys.defaultRemotePath) ?? ""

        let port = userDefaults.integer(forKey: Keys.defaultPort)
        self.defaultPort = (1...65535).contains(port) ? port : 22

        self.defaultUsername = userDefaults.string(forKey: Keys.defaultUsername) ?? NSUserName()

        refreshLaunchAtLoginStatus()
        writeTuning()
    }

    func refreshLaunchAtLoginStatus() {
        self.launchAtLoginStatus = SMAppService.mainApp.status
    }

    func setLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // ServiceManagement may throw if running in un-packaged/debug environment
        }
        refreshLaunchAtLoginStatus()
    }

    func resetToDefaults() {
        openInFinderOnMount = true
        notifyOnConnectionError = true
        notifyOnMount = false
        notifyOnDisconnect = false
        defaultParallelTransfers = 3
        defaultRefreshInterval = 60.0
        defaultShowHiddenFiles = true
        defaultKeepAllDownloaded = false
        prefetchEnabled = true
        prefetchMaxFileMB = 5
        prefetchMaxFolderMB = 50
        defaultRemotePath = ""
        defaultPort = 22
        defaultUsername = NSUserName()
    }

    private func writeTuning() {
        guard writesTuning else { return }
        FinderTuning.save(FinderTuning(
            prefetchEnabled: prefetchEnabled,
            maxFileBytes: Int64(prefetchMaxFileMB) * 1024 * 1024,
            maxFolderBytes: Int64(prefetchMaxFolderMB) * 1024 * 1024))
    }
}
