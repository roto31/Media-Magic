import SwiftUI

struct LogViewerView: View {
    @EnvironmentObject private var pipeline: PipelineController
    @State private var searchText: String = ""
    @State private var selectedProcess: PipelineLogProcess?
    @State private var autoScroll: Bool = true

    var body: some View {
        VStack(spacing: 10) {
            filterBar
            Divider()
            logList
        }
        .padding(12)
        .frame(minWidth: 900, minHeight: 560)
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            TextField("Search log output", text: $searchText)
                .textFieldStyle(.roundedBorder)

            Picker("Process", selection: $selectedProcess) {
                Text("All Processes").tag(Optional<PipelineLogProcess>.none)
                ForEach(PipelineLogProcess.allCases) { process in
                    Text(process.rawValue).tag(Optional(process))
                }
            }
            .pickerStyle(.menu)
            .frame(width: 220)

            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.switch)

            Spacer()

            if !pipeline.currentLogFilePath.isEmpty {
                Text(pipeline.currentLogFilePath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            } else {
                Text("No active run log file yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            List(filteredEntries) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Text(Self.timeFormatter.string(from: entry.timestamp))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)

                    Text(entry.process.rawValue)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(processColor(entry.process).opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .frame(width: 120, alignment: .leading)

                    Text(entry.message)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .id(entry.id)
            }
            .onChange(of: filteredEntries.count) { _ in
                guard autoScroll, let last = filteredEntries.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var filteredEntries: [PipelineLogEntry] {
        pipeline.logEntries.filter { entry in
            let processMatch = selectedProcess == nil || selectedProcess == entry.process
            guard processMatch else { return false }
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return true }
            return entry.message.localizedCaseInsensitiveContains(q)
                || entry.process.rawValue.localizedCaseInsensitiveContains(q)
        }
    }

    private func processColor(_ process: PipelineLogProcess) -> Color {
        switch process {
        case .system: return .gray
        case .makeMKV: return .purple
        case .handBrake: return .blue
        case .fileBot: return .orange
        case .fileBotScript: return .teal
        case .subler: return .green
        case .appleTVImport: return .indigo
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
