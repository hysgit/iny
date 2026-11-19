import Foundation

enum FTPDirectoryParser {
    static func parse(_ listing: String, parent: String, machine: Bool) -> [RemoteEntry] {
        listing.components(separatedBy: .newlines).compactMap { line in
            let name: String; let folder: Bool
            if machine {
                guard let separator = line.firstIndex(of: " ") else { return nil }
                let facts = String(line[..<separator]).lowercased(); name = String(line[line.index(after: separator)...])
                if facts.contains("type=cdir") || facts.contains("type=pdir") { return nil }
                folder = facts.contains("type=dir;")
            } else {
                let fields = line.split(maxSplits: 8, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
                guard fields.count == 9 else { return nil }
                folder = fields[0].hasPrefix("d"); name = String(fields[8])
            }
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), folder || MediaFormats.isVideo(name) else { return nil }
            let path = (parent as NSString).appendingPathComponent(name)
            return RemoteEntry(id: path, name: name, isDirectory: folder, path: path)
        }
    }
}
