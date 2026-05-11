import Foundation

/// Names recognized by FileBot `--db` for typical Media Magic rename workflows.
/// Reference: https://www.filebot.net/cli.html
enum FileBotDatabaseChoice: String, CaseIterable, Identifiable {
    case theMovieDB = "TheMovieDB"
    case theMovieDBTV = "TheMovieDB::TV"
    case theTVDB = "TheTVDB"
    case aniDB = "AniDB"
    case omdb = "OMDb"
    case custom

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .theMovieDB: return "TheMovieDB (movies)"
        case .theMovieDBTV: return "TheMovieDB::TV (series)"
        case .theTVDB: return "TheTVDB"
        case .aniDB: return "AniDB"
        case .omdb: return "OMDb"
        case .custom: return "Custom…"
        }
    }

    static func matchingStored(_ db: String) -> FileBotDatabaseChoice {
        for c in Self.allCases where c != .custom && c.rawValue == db {
            return c
        }
        return .custom
    }
}

enum FileBotNamingPreset: String, CaseIterable, Identifiable {
    case movie
    case tv
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .movie: return "Movie"
        case .tv: return "TV"
        case .custom: return "Custom"
        }
    }

    static let movieFormatDefault = "{n} ({y})"
    static let tvFormatDefault = "{s00e00} {n} - {t}"
}

/// Episode numbering order for FileBot `--order`.
enum FileBotEpisodeOrder: String, CaseIterable, Identifiable {
    case notSpecified = ""
    case airdate = "Airdate"
    case absolute = "Absolute"
    case dvd = "DVD"
    case dateAndTitle = "Date and Title"

    var id: String { rawValue.isEmpty ? "notSpecified" : rawValue }

    var menuLabel: String {
        switch self {
        case .notSpecified: return "Default"
        case .airdate: return "Airdate"
        case .absolute: return "Absolute"
        case .dvd: return "DVD"
        case .dateAndTitle: return "Date and Title"
        }
    }
}
