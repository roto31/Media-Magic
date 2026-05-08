import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let handBrakePreset = "settings.handbrake.preset"
        static let handBrakeExtraArgs = "settings.handbrake.extraArgs"
        static let fileBotDB = "settings.filebot.db"
        static let fileBotFormat = "settings.filebot.format"
        static let fileBotExtraArgs = "settings.filebot.extraArgs"
        static let sublerExtraArgs = "settings.subler.extraArgs"
        static let defaultSkipFileBot = "settings.defaults.skipFileBot"
        static let defaultSkipSubler = "settings.defaults.skipSubler"
        static let defaultCopyToAppleTVImport = "settings.defaults.copyToAppleTVImport"
        static let forceFirstRunSetup = "settings.tools.forceFirstRunSetup"
    }

    @Published var handBrakePreset: String { didSet { save(Keys.handBrakePreset, handBrakePreset) } }
    @Published var handBrakeExtraArgs: String { didSet { save(Keys.handBrakeExtraArgs, handBrakeExtraArgs) } }
    @Published var fileBotDB: String { didSet { save(Keys.fileBotDB, fileBotDB) } }
    @Published var fileBotFormat: String { didSet { save(Keys.fileBotFormat, fileBotFormat) } }
    @Published var fileBotExtraArgs: String { didSet { save(Keys.fileBotExtraArgs, fileBotExtraArgs) } }
    @Published var sublerExtraArgs: String { didSet { save(Keys.sublerExtraArgs, sublerExtraArgs) } }
    @Published var defaultSkipFileBot: Bool { didSet { save(Keys.defaultSkipFileBot, defaultSkipFileBot) } }
    @Published var defaultSkipSubler: Bool { didSet { save(Keys.defaultSkipSubler, defaultSkipSubler) } }
    @Published var defaultCopyToAppleTVImport: Bool { didSet { save(Keys.defaultCopyToAppleTVImport, defaultCopyToAppleTVImport) } }
    @Published var forceFirstRunSetupOnNextLaunch: Bool { didSet { save(Keys.forceFirstRunSetup, forceFirstRunSetupOnNextLaunch) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        handBrakePreset = defaults.string(forKey: Keys.handBrakePreset) ?? "Apple 2160p60 4K HEVC Surround"
        handBrakeExtraArgs = defaults.string(forKey: Keys.handBrakeExtraArgs) ?? ""
        fileBotDB = defaults.string(forKey: Keys.fileBotDB) ?? "TheMovieDB"
        fileBotFormat = defaults.string(forKey: Keys.fileBotFormat) ?? "{n} ({y})"
        fileBotExtraArgs = defaults.string(forKey: Keys.fileBotExtraArgs) ?? "-non-strict --action move --conflict auto"
        sublerExtraArgs = defaults.string(forKey: Keys.sublerExtraArgs) ?? ""
        defaultSkipFileBot = defaults.bool(forKey: Keys.defaultSkipFileBot)
        defaultSkipSubler = defaults.bool(forKey: Keys.defaultSkipSubler)
        defaultCopyToAppleTVImport = defaults.bool(forKey: Keys.defaultCopyToAppleTVImport)
        forceFirstRunSetupOnNextLaunch = defaults.bool(forKey: Keys.forceFirstRunSetup)
    }

    func args(from raw: String) -> [String] {
        raw.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    private let defaults: UserDefaults

    private func save(_ key: String, _ value: String) {
        defaults.set(value, forKey: key)
    }

    private func save(_ key: String, _ value: Bool) {
        defaults.set(value, forKey: key)
    }
}
