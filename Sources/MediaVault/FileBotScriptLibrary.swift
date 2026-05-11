import Foundation

/// Identifies a FileBot `-script` target: built-in `fn:*` or a bundled `.groovy` file (GPLv3 upstream).
struct FileBotScriptDescriptor: Identifiable, Hashable {
    /// Stable key for pickers and persistence, e.g. `builtin:fn:amc`, `bundle:artwork.groovy`
    let id: String
    let title: String
    /// Second argument to `-script` (either `fn:amc` or an absolute path to a `.groovy` file).
    let scriptArgument: String
    let isBuiltinFN: Bool

    static let builtinFNAMC = FileBotScriptDescriptor(
        id: "builtin:fn:amc",
        title: "AMC — Automated Media Center (fn:amc)",
        scriptArgument: "fn:amc",
        isBuiltinFN: true
    )
}

enum FileBotScriptLibrary {

    private static let bundledSubdirectory = "FileBotScripts"

    /// Built-in script names shipped with FileBot (no file on disk).
    static var builtinDescriptors: [FileBotScriptDescriptor] {
        [ .builtinFNAMC ]
    }

    /// Scans `Bundle.main` for vendored `*.groovy` from https://github.com/filebot/scripts (GPLv3).
    static func bundledDescriptors(bundle: Bundle = .main) -> [FileBotScriptDescriptor] {
        guard let url = bundle.resourceURL?.appendingPathComponent(bundledSubdirectory, isDirectory: true),
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return []
        }
        return names.filter { $0.hasSuffix(".groovy") }.sorted().map { name in
            let path = url.appendingPathComponent(name).path
            return FileBotScriptDescriptor(
                id: "bundle:\(name)",
                title: name.replacingOccurrences(of: ".groovy", with: ""),
                scriptArgument: path,
                isBuiltinFN: false
            )
        }
    }

    static func allDescriptors(bundle: Bundle = .main) -> [FileBotScriptDescriptor] {
        builtinDescriptors + bundledDescriptors(bundle: bundle)
    }

    static func descriptor(withId id: String, bundle: Bundle = .main) -> FileBotScriptDescriptor? {
        allDescriptors(bundle: bundle).first { $0.id == id }
    }

    /// Parses multiline `key=value` into repeated `--def` argv pairs (FileBot CLI / AMC style).
    static func argvForDefBlock(_ block: String) -> [String] {
        var out: [String] = []
        for line in block.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            out.append(contentsOf: ["--def", t])
        }
        return out
    }

    /// Builds argv after the `filebot` binary: `-script` … extras … defs … input.
    static func scriptProcessArguments(
        descriptorId: String,
        inputMediaPath: String,
        extraArgsRaw: String,
        defBlock: String,
        bundle: Bundle = .main
    ) throws -> [String] {
        guard let d = descriptor(withId: descriptorId, bundle: bundle) else {
            throw NSError(
                domain: "MediaVault", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Unknown FileBot script: \(descriptorId)"]
            )
        }
        let extras = extraArgsRaw.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let defs = argvForDefBlock(defBlock)
        var args = ["-script", d.scriptArgument]
        args.append(contentsOf: extras)
        args.append(contentsOf: defs)
        args.append(inputMediaPath)
        return args
    }
}
