import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct FilenameMetadata: Equatable, Sendable {
    var title: String
    var year: Int?
    var season: Int?
    var episode: Int?

    static func parse(_ filename: String) -> Self {
        let stem = (filename as NSString).deletingPathExtension
        let range = NSRange(stem.startIndex..., in: stem)
        let episodes = try! NSRegularExpression(pattern: #"(?i)[ ._-](?:s(\d{1,3})[ ._-]*e(\d{1,4})|(\d{1,3})x(\d{1,4}))(?:\D|$)"#)
        var result = Self(title: MediaFormats.title(filename))
        var cut = stem.endIndex
        if let match = episodes.firstMatch(in: stem, range: range) {
            func number(_ n: Int) -> Int? { Range(match.range(at: n), in: stem).flatMap { Int(stem[$0]) } }
            result.season = number(1) ?? number(3); result.episode = number(2) ?? number(4)
            cut = Range(match.range, in: stem)!.lowerBound
        }
        let years = try! NSRegularExpression(pattern: #"[ ._(\[]((?:19|20)\d{2})(?:[ ._)\]]|$)"#)
        if let match = years.firstMatch(in: stem, range: range), let digits = Range(match.range(at: 1), in: stem),
           let start = Range(match.range, in: stem)?.lowerBound {
            result.year = Int(stem[digits]); cut = min(cut, start)
        }
        result.title = String(stem[..<cut]).replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if result.title.isEmpty { result.title = MediaFormats.title(filename) }
        return result
    }
}

struct NFOMetadata: Sendable {
    var title: String?
    var showTitle: String?
    var plot: String?
    var year: Int?
    var season: Int?
    var episode: Int?
    var collection: String?
    var rating: Double?
    var certification: String?
    var tmdbID: Int?
    var cast: [MediaPerson] = []

    func apply(to item: inout MediaItem) {
        if let title, !title.isEmpty { item.title = title }
        if let plot { item.overview = plot }
        item.seriesTitle = showTitle ?? item.seriesTitle
        item.year = year ?? item.year; item.season = season ?? item.season; item.episode = episode ?? item.episode
        item.collection = collection ?? item.collection; item.rating = rating ?? item.rating
        item.certification = certification ?? item.certification; item.tmdbID = tmdbID ?? item.tmdbID
        if !cast.isEmpty { item.cast = cast }
        if item.episode != nil { item.mediaType = "tv" }
    }

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 4 * 1024 * 1024 else { throw AppError.message("NFO 文件超过 4 MB。") }
        let delegate = NFOParser(); let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), parser.parserError == nil, delegate.depth == 0, delegate.rootValid else { throw AppError.message("NFO 格式无效。") }
        return delegate.result
    }
}

private final class NFOParser: NSObject, XMLParserDelegate {
    var result = NFOMetadata()
    var depth = 0
    var rootValid = false
    private var stack: [String] = []
    private var texts: [String] = []
    private var person: MediaPerson?
    private var uniqueType = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1; stack.append(name); texts.append("")
        if depth == 1 { rootValid = ["movie", "episodedetails", "tvshow"].contains(name) }
        if name == "actor" { person = MediaPerson(name: "") }
        if name == "uniqueid" { uniqueType = attributes["type"] ?? "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if !texts.isEmpty { texts[texts.count - 1] += string } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { if let text = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: text) } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let text = (texts.popLast() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        _ = stack.popLast(); depth -= 1
        if person != nil {
            if name == "name" { person?.name = text }
            if name == "role" { person?.role = text }
            if name == "actor" { if let person, !person.name.isEmpty { result.cast.append(person) }; person = nil }
            return
        }
        switch name {
        case "title": result.title = text
        case "showtitle": result.showTitle = text
        case "plot": result.plot = text
        case "year": result.year = Int(text)
        case "season": result.season = Int(text)
        case "episode": result.episode = Int(text)
        case "mpaa": result.certification = text
        case "rating", "value": if let rating = Double(text), (0...10).contains(rating) { result.rating = rating }
        case "uniqueid": if uniqueType == "tmdb" { result.tmdbID = Int(text) }
        case "name": if stack.last == "set" { result.collection = text }
        default: break
        }
    }
}
