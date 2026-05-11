import SwiftUI

/// Preferences window content (also used by SwiftUI `Settings` scene).
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var presetStore: AutomationPresetStore
    @State private var saveSettingsPresetName = ""
    @State private var showSaveSettingsPresetAlert = false

    private var databasePickerSelection: Binding<FileBotDatabaseChoice> {
        Binding(
            get: { FileBotDatabaseChoice.matchingStored(settings.fileBotDB) },
            set: { choice in
                if choice != .custom {
                    settings.fileBotDB = choice.rawValue
                }
            }
        )
    }

    private var namingPresetBinding: Binding<FileBotNamingPreset> {
        Binding(
            get: { settings.fileBotNamingPreset },
            set: { settings.applyNamingPreset($0) }
        )
    }

    private var episodeOrderBinding: Binding<FileBotEpisodeOrder> {
        Binding(
            get: { settings.fileBotEpisodeOrder },
            set: { settings.fileBotEpisodeOrder = $0 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)

                GroupBox("HandBrake") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Preset", text: $settings.handBrakePreset)
                        TextField("Extra args (space-separated)", text: $settings.handBrakeExtraArgs)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(8)
                }

                GroupBox("FileBot") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Database", selection: databasePickerSelection) {
                            ForEach(FileBotDatabaseChoice.allCases) { choice in
                                Text(choice.menuLabel).tag(choice)
                            }
                        }
                        if FileBotDatabaseChoice.matchingStored(settings.fileBotDB) == .custom {
                            TextField("Custom --db value", text: $settings.fileBotDB)
                                .textFieldStyle(.roundedBorder)
                        }

                        Picker("Naming preset", selection: namingPresetBinding) {
                            ForEach(FileBotNamingPreset.allCases) { preset in
                                Text(preset.label).tag(preset)
                            }
                        }
                        TextField("Format expression (--format)", text: $settings.fileBotFormat)
                            .textFieldStyle(.roundedBorder)
                        Text("Movie default: \(FileBotNamingPreset.movieFormatDefault) · TV default: \(FileBotNamingPreset.tvFormatDefault)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("Episode order (--order)", selection: episodeOrderBinding) {
                            ForEach(FileBotEpisodeOrder.allCases) { order in
                                Text(order.menuLabel).tag(order)
                            }
                        }
                        Text("Used for TV episode numbering. See FileBot CLI docs when matching episodes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Toggle("Also fetch artwork files (--apply artwork)", isOn: $settings.fileBotApplyArtwork)

                        TextField("Extra args (space-separated)", text: $settings.fileBotExtraArgs)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(8)
                }

                GroupBox("Subler") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            "Media Magic runs SublerCli with `-source` and `-optimize`, which muxes metadata and artwork into the file. SublerCli does not use FileBot-style `--db` selectors; adjust optional flags below only if your installed SublerCli supports them (see Help)."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        TextField("Extra args (space-separated)", text: $settings.sublerExtraArgs)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(8)
                }

                GroupBox("Automation presets") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Saved batch profiles for FileBot rename + optional scripts (GPLv3 Groovy library is bundled in the app).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        List {
                            ForEach(presetStore.presets) { p in
                                HStack {
                                    Text(p.name)
                                    Spacer()
                                    Button {
                                        presetStore.remove(id: p.id)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Delete preset")
                                }
                            }
                        }
                        .frame(minHeight: 100)
                        Button("Save current Settings as preset…") {
                            saveSettingsPresetName = ""
                            showSaveSettingsPresetAlert = true
                        }
                    }
                    .padding(8)
                }

                GroupBox("Defaults") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Default: Skip FileBot", isOn: $settings.defaultSkipFileBot)
                        Toggle("Default: Skip Subler", isOn: $settings.defaultSkipSubler)
                        Toggle(
                            "Default: Copy completed file to Apple TV auto-import folder",
                            isOn: $settings.defaultCopyToAppleTVImport
                        )
                        Toggle(
                            "Force first-run setup on next launch (re-download HandBrakeCLI)",
                            isOn: $settings.forceFirstRunSetupOnNextLaunch
                        )
                    }
                    .padding(8)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 640, minHeight: 560)
        .alert("Save preset from Settings", isPresented: $showSaveSettingsPresetAlert) {
            TextField("Preset name", text: $saveSettingsPresetName)
            Button("Save") {
                let name = saveSettingsPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                presetStore.save(AutomationPreset(from: settings, name: name))
                saveSettingsPresetName = ""
            }
            Button("Cancel", role: .cancel) {
                saveSettingsPresetName = ""
            }
        } message: {
            Text("Captures the FileBot options above into a batch preset for the main window.")
        }
    }
}
