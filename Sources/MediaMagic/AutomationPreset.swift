import Foundation

/// Per-batch automation fields on the main window (merged into `PipelineRunOptions`).
struct RunAutomationFields: Equatable {
    var fileBotDB: String
    var fileBotFormat: String
    var fileBotEpisodeOrder: String
    var fileBotApplyArtwork: Bool
    var fileBotExtraArgs: String
    var postScriptEnabled: Bool
    var postScriptDescriptorId: String
    var postScriptExtraArgs: String
    var postScriptDefBlock: String
    var postScriptInputIsParentFolder: Bool

    init(
        fileBotDB: String,
        fileBotFormat: String,
        fileBotEpisodeOrder: String,
        fileBotApplyArtwork: Bool,
        fileBotExtraArgs: String,
        postScriptEnabled: Bool,
        postScriptDescriptorId: String,
        postScriptExtraArgs: String,
        postScriptDefBlock: String,
        postScriptInputIsParentFolder: Bool
    ) {
        self.fileBotDB = fileBotDB
        self.fileBotFormat = fileBotFormat
        self.fileBotEpisodeOrder = fileBotEpisodeOrder
        self.fileBotApplyArtwork = fileBotApplyArtwork
        self.fileBotExtraArgs = fileBotExtraArgs
        self.postScriptEnabled = postScriptEnabled
        self.postScriptDescriptorId = postScriptDescriptorId
        self.postScriptExtraArgs = postScriptExtraArgs
        self.postScriptDefBlock = postScriptDefBlock
        self.postScriptInputIsParentFolder = postScriptInputIsParentFolder
    }

    @MainActor
    init(from settings: AppSettings) {
        fileBotDB = settings.fileBotDB
        fileBotFormat = settings.fileBotFormat
        fileBotEpisodeOrder = settings.fileBotEpisodeOrder.rawValue
        fileBotApplyArtwork = settings.fileBotApplyArtwork
        fileBotExtraArgs = settings.fileBotExtraArgs
        postScriptEnabled = settings.fileBotPostScriptEnabled
        postScriptDescriptorId = settings.fileBotPostScriptDescriptorId
        postScriptExtraArgs = settings.fileBotPostScriptExtraArgs
        postScriptDefBlock = settings.fileBotPostScriptDefBlock
        postScriptInputIsParentFolder = settings.fileBotPostScriptInputIsParentFolder
    }

    init(from preset: AutomationPreset) {
        fileBotDB = preset.fileBotDB
        fileBotFormat = preset.fileBotFormat
        fileBotEpisodeOrder = preset.fileBotEpisodeOrder
        fileBotApplyArtwork = preset.fileBotApplyArtwork
        fileBotExtraArgs = preset.fileBotExtraArgs
        postScriptEnabled = preset.postScriptEnabled
        postScriptDescriptorId = preset.postScriptDescriptorId
        postScriptExtraArgs = preset.postScriptExtraArgs
        postScriptDefBlock = preset.postScriptDefBlock
        postScriptInputIsParentFolder = preset.postScriptInputIsParentFolder
    }

    func asPreset(name: String, id: UUID = UUID()) -> AutomationPreset {
        AutomationPreset(
            id: id,
            name: name,
            fileBotDB: fileBotDB,
            fileBotFormat: fileBotFormat,
            fileBotEpisodeOrder: fileBotEpisodeOrder,
            fileBotApplyArtwork: fileBotApplyArtwork,
            fileBotExtraArgs: fileBotExtraArgs,
            postScriptEnabled: postScriptEnabled,
            postScriptDescriptorId: postScriptDescriptorId,
            postScriptExtraArgs: postScriptExtraArgs,
            postScriptDefBlock: postScriptDefBlock,
            postScriptInputIsParentFolder: postScriptInputIsParentFolder
        )
    }
}

/// Saved batch profile: FileBot rename options + optional post-rename `filebot -script` automation.
struct AutomationPreset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var fileBotDB: String
    var fileBotFormat: String
    var fileBotEpisodeOrder: String
    var fileBotApplyArtwork: Bool
    var fileBotExtraArgs: String
    var postScriptEnabled: Bool
    /// `FileBotScriptDescriptor.id` or empty when disabled / none
    var postScriptDescriptorId: String
    var postScriptExtraArgs: String
    var postScriptDefBlock: String
    var postScriptInputIsParentFolder: Bool

    init(
        id: UUID = UUID(),
        name: String,
        fileBotDB: String,
        fileBotFormat: String,
        fileBotEpisodeOrder: String,
        fileBotApplyArtwork: Bool,
        fileBotExtraArgs: String,
        postScriptEnabled: Bool,
        postScriptDescriptorId: String,
        postScriptExtraArgs: String,
        postScriptDefBlock: String,
        postScriptInputIsParentFolder: Bool
    ) {
        self.id = id
        self.name = name
        self.fileBotDB = fileBotDB
        self.fileBotFormat = fileBotFormat
        self.fileBotEpisodeOrder = fileBotEpisodeOrder
        self.fileBotApplyArtwork = fileBotApplyArtwork
        self.fileBotExtraArgs = fileBotExtraArgs
        self.postScriptEnabled = postScriptEnabled
        self.postScriptDescriptorId = postScriptDescriptorId
        self.postScriptExtraArgs = postScriptExtraArgs
        self.postScriptDefBlock = postScriptDefBlock
        self.postScriptInputIsParentFolder = postScriptInputIsParentFolder
    }

    @MainActor
    init(from settings: AppSettings, name: String, id: UUID = UUID()) {
        let r = RunAutomationFields(from: settings)
        self.init(
            id: id,
            name: name,
            fileBotDB: r.fileBotDB,
            fileBotFormat: r.fileBotFormat,
            fileBotEpisodeOrder: r.fileBotEpisodeOrder,
            fileBotApplyArtwork: r.fileBotApplyArtwork,
            fileBotExtraArgs: r.fileBotExtraArgs,
            postScriptEnabled: r.postScriptEnabled,
            postScriptDescriptorId: r.postScriptDescriptorId,
            postScriptExtraArgs: r.postScriptExtraArgs,
            postScriptDefBlock: r.postScriptDefBlock,
            postScriptInputIsParentFolder: r.postScriptInputIsParentFolder
        )
    }
}

@MainActor
final class AutomationPresetStore: ObservableObject {
    private let defaults: UserDefaults
    private let key = "automation.presets.v1"

    @Published private(set) var presets: [AutomationPreset] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([AutomationPreset].self, from: data) else {
            presets = []
            return
        }
        presets = decoded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: key)
        }
    }

    func save(_ preset: AutomationPreset) {
        if let i = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[i] = preset
        } else {
            presets.append(preset)
        }
        presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
    }

    func remove(id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    func preset(id: UUID?) -> AutomationPreset? {
        guard let id else { return nil }
        return presets.first { $0.id == id }
    }
}
