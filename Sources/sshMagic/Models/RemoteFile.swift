import Foundation

/// One entry in a remote directory listing.
struct RemoteFile: Identifiable, Hashable {
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64
    /// Raw date columns from the listing (e.g. "Jun 12 14:00"), for display.
    let modified: String

    var id: String { name }

    /// SF Symbol for the row icon.
    var icon: String {
        if isDirectory { return "folder.fill" }
        if isSymlink { return "arrow.up.right.square" }
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff": return "photo"
        case "zip", "gz", "tar", "tgz", "bz2", "xz", "7z", "rar": return "doc.zipper"
        case "sh", "bash", "zsh", "py", "rb", "pl", "js", "ts": return "terminal"
        case "c", "h", "cpp", "hpp", "swift", "go", "rs", "java": return "chevron.left.forwardslash.chevron.right"
        case "md", "txt", "log", "cfg", "conf", "ini", "yaml", "yml", "json", "toml": return "doc.text"
        case "pdf": return "doc.richtext"
        case "mp3", "wav", "flac", "aac", "ogg": return "music.note"
        case "mp4", "mov", "mkv", "avi", "webm": return "film"
        default: return "doc"
        }
    }

    /// Human-readable size, blank for directories.
    var sizeText: String {
        guard !isDirectory else { return "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

extension RemoteFile {
    /// Parse the long-format output of `sftp`'s `ls -la`. Lines that aren't
    /// listing rows (the `sftp>` prompt echo, blank lines) are skipped. `.` and
    /// `..` are filtered out — navigation uses the path bar instead.
    static func parse(lsOutput: String) -> [RemoteFile] {
        lsOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parse(line: String($0)) }
            .filter { $0.name != "." && $0.name != ".." }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// Parse a single `ls -l`-style line, or nil if it isn't one.
    static func parse(line: String) -> RemoteFile? {
        // perms links owner group size mon day time/year name...
        // The 8 metadata fields are tokenized, but the name (everything after
        // them) is taken VERBATIM from the line: splitting and rejoining would
        // collapse runs of spaces/tabs inside the filename, silently renaming
        // it in the model — and every path later built from that name (rm,
        // get, edit) would target a different remote file.
        func isSeparator(_ c: Character) -> Bool { c == " " || c == "\t" }
        var fields: [Substring] = []
        var index = line.startIndex
        while fields.count < 8, index < line.endIndex {
            while index < line.endIndex, isSeparator(line[index]) {
                index = line.index(after: index)
            }
            let start = index
            while index < line.endIndex, !isSeparator(line[index]) {
                index = line.index(after: index)
            }
            guard start < index else { break }
            fields.append(line[start..<index])
        }
        // Skip the separator run between the last metadata field and the name.
        while index < line.endIndex, isSeparator(line[index]) {
            index = line.index(after: index)
        }
        guard fields.count == 8, index < line.endIndex else { return nil }

        let perms = fields[0]
        guard perms.count == 10 || perms.count == 11, let type = perms.first else { return nil }
        guard "dl-bcps".contains(type) else { return nil }

        let isDirectory = type == "d"
        let isSymlink = type == "l"
        let size = Int64(fields[4]) ?? 0
        let modified = fields[5...7].joined(separator: " ")

        var name = String(line[index...])
        // Symlinks render as "name -> target"; keep just the link name.
        if isSymlink, let arrow = name.range(of: " -> ") {
            name = String(name[..<arrow.lowerBound])
        }
        // Some sftp servers prefix entries with the full directory path when you
        // `ls <path>` (e.g. "/home/astro/.bashrc"); reduce to the basename so the
        // row label and path-joining are correct. A filename can't contain "/",
        // so this is always safe.
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        guard !name.isEmpty else { return nil }

        return RemoteFile(
            name: name,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: size,
            modified: modified
        )
    }
}
