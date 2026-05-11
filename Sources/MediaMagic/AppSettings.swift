import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let handBrakePreset = "settings.handbrake.preset"
        static let handBrakeExtraArgs = "settings.handbrake.extraArgs"
        static let fileBotDB = "settings.filebot.db"
        static let fileBotFormat = "settings.filebot.format"
        static let fileBotExtraArgs = "settings.filebot.extraArgs"
        static let fileBotNamingPreset = "settings.filebot.namingPreset"
        static let fileBotEpisodeOrder = "settings.filebot.episodeOrder"
        static let fileBotApplyArtwork = "settings.filebot.applyArtwork"
        static let fileBotPostScriptEnabled = "settings.filebot.postScript.enabled"
        static let fileBotPostScriptDescriptorId = "settings.filebot.postScript.descriptorId"
        static let fileBotPostScriptExtraArgs = "settings.filebot.postScript.extraArgs"
        static let fileBotPostScriptDefBlock = "settings.filebot.postScript.defBlock"
        static let fileBotPostScriptInputIsParentFolder = "settings.filebot.postScript.inputIsParentFolder"
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
    @Published var fileBotNamingPresetRaw: String {
        didSet { save(Keys.fileBotNamingPreset, fileBotNamingPresetRaw) }
    }
    @Published var fileBotEpisodeOrderRaw: String {
        didSet { save(Keys.fileBotEpisodeOrder, fileBotEpisodeOrderRaw) }
    }
    @Published var fileBotApplyArtwork: Bool {
        didSet { save(Keys.fileBotApplyArtwork, fileBotApplyArtwork) }
    }
    @Published var fileBotPostScriptEnabled: Bool {
        didSet { save(Keys.fileBotPostScriptEnabled, fileBotPostScriptEnabled) }
    }
    @Published var fileBotPostScriptDescriptorId: String {
        didSet { save(Keys.fileBotPostScriptDescriptorId, fileBotPostScriptDescriptorId) }
    }
    @Published var fileBotPostScriptExtraArgs: String {
        didSet { save(Keys.fileBotPostScriptExtraArgs, fileBotPostScriptExtraArgs) }
    }
    @Published var fileBotPostScriptDefBlock: String {
        didSet { save(Keys.fileBotPostScriptDefBlock, fileBotPostScriptDefBlock) }
    }
    @Published var fileBotPostScriptInputIsParentFolder: Bool {
        didSet { save(Keys.fileBotPostScriptInputIsParentFolder, fileBotPostScriptInputIsParentFolder) }
    }
    @Published var sublerExtraArgs: String { didSet { save(Keys.sublerExtraArgs, sublerExtraArgs) } }
    @Published var defaultSkipFileBot: Bool { didSet { save(Keys.defaultSkipFileBot, defaultSkipFileBot) } }
    @Published var defaultSkipSubler: Bool { didSet { save(Keys.defaultSkipSubler, defaultSkipSubler) } }
    @Published var defaultCopyToAppleTVImport: Bool {
        didSet { save(Keys.defaultCopyToAppleTVImport, defaultCopyToAppleTVImport) }
    }
    @Published var forceFirstRunSetupOnNextLaunch: Bool {
        didSet { save(Keys.forceFirstRunSetup, forceFirstRunSetupOnNextLaunch) }
    }

    var fileBotNamingPreset: FileBotNamingPreset {
        get { FileBotNamingPreset(rawValue: fileBotNamingPresetRaw) ?? .movie }
        set { fileBotNamingPresetRaw = newValue.rawValue }
    }

    var fileBotEpisodeOrder: FileBotEpisodeOrder {
        get {
            if fileBotEpisodeOrderRaw.isEmpty { return .notSpecified }
            return FileBotEpisodeOrder(rawValue: fileBotEpisodeOrderRaw) ?? .notSpecified
        }
        set { fileBotEpisodeOrderRaw = newValue.rawValue }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        handBrakePreset = defaults.string(forKey: Keys.handBrakePreset) ?? "Apple 2160p60 4K HEVC Surround"
        handBrakeExtraArgs = defaults.string(forKey: Keys.handBrakeExtraArgs) ?? ""
        fileBotDB = defaults.string(forKey: Keys.fileBotDB) ?? "TheMovieDB"
        fileBotFormat = defaults.string(forKey: Keys.fileBotFormat) ?? FileBotNamingPreset.movieFormatDefault
        fileBotExtraArgs = defaults.string(forKey: Keys.fileBotExtraArgs) ?? "-non-strict --action move --conflict auto"
        fileBotNamingPresetRaw = defaults.string(forKey: Keys.fileBotNamingPreset)
            ?? FileBotNamingPreset.movie.rawValue
        fileBotEpisodeOrderRaw = defaults.string(forKey: Keys.fileBotEpisodeOrder) ?? ""
        fileBotApplyArtwork = defaults.bool(forKey: Keys.fileBotApplyArtwork)
        fileBotPostScriptEnabled = defaults.bool(forKey: Keys.fileBotPostScriptEnabled)
        fileBotPostScriptDescriptorId = defaults.string(forKey: Keys.fileBotPostScriptDescriptorId) ?? ""
        fileBotPostScriptExtraArgs = defaults.string(forKey: Keys.fileBotPostScriptExtraArgs) ?? ""
        fileBotPostScriptDefBlock = defaults.string(forKey: Keys.fileBotPostScriptDefBlock) ?? ""
        fileBotPostScriptInputIsParentFolder = defaults.bool(forKey: Keys.fileBotPostScriptInputIsParentFolder)
        sublerExtraArgs = defaults.string(forKey: Keys.sublerExtraArgs) ?? ""
        defaultSkipFileBot = defaults.bool(forKey: Keys.defaultSkipFileBot)
        defaultSkipSubler = defaults.bool(forKey: Keys.defaultSkipSubler)
        defaultCopyToAppleTVImport = defaults.bool(forKey: Keys.defaultCopyToAppleTVImport)
        forceFirstRunSetupOnNextLaunch = defaults.bool(forKey: Keys.forceFirstRunSetup)
    }

    func args(from raw: String) -> [String] {
        raw.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    /// Applies built-in format strings when switching naming preset.
    func applyNamingPreset(_ preset: FileBotNamingPreset) {
        fileBotNamingPresetRaw = preset.rawValue
        switch preset {
        case .movie:
            fileBotFormat = FileBotNamingPreset.movieFormatDefault
        case .tv:
            fileBotFormat = FileBotNamingPreset.tvFormatDefault
        case .custom:
            break
        }
    }

    private let defaults: UserDefaults

    private func save(_ key: String, _ value: String) {
        defaults.set(value, forKey: key)
    }

    private func save(_ key: String, _ value: Bool) {
        defaults.set(value, forKey: key)
    }
}
