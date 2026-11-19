import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

final class WebDAVParser: NSObject, XMLParserDelegate {
    private struct Response {
        var href = ""
        var properties: [String: String] = [:]
        var folder = false
        var successful = false
    }
    private var responses: [Response] = []
    private var response = Response()
    private var props: [String: String] = [:]
    private var folder = false
    private var status = ""
    private var inProperties = false
    private var inPropstat = false
    private var element = ""
    private var buffer = ""

    static func parse(_ data: Data, relativeTo base: URL) throws -> [RemoteEntry] {
        let delegate = WebDAVParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw AppError.message("WebDAV 目录 XML 无法解析。") }
        return delegate.responses.compactMap { value in
            guard value.successful else { return nil }
            guard let url = URL(string: value.href, relativeTo: base)?.absoluteURL,
                  url.scheme?.lowercased() == base.scheme?.lowercased(),
                  url.host?.lowercased() == base.host?.lowercased(), url.port == base.port else { return nil }
            let path = url.path
            guard path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { return nil }
            guard value.folder || MediaFormats.isVideo(path) else { return nil }
            return RemoteEntry(id: url.absoluteString, name: value.properties["displayname"].flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent,
                               isDirectory: value.folder, path: url.absoluteString)
        }.sorted { a, b in
            a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        element = name; buffer = ""
        if name == "response" { response = Response() }
        if name == "propstat" { inPropstat = true; props = [:]; folder = false; status = "" }
        if name == "prop" { inProperties = true }
        if name == "collection", inProperties { folder = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "href", !inProperties { response.href = buffer.trimmingCharacters(in: .whitespacesAndNewlines) }
        if name == "displayname", inProperties { props[name] = buffer }
        if name == "status", inPropstat { status = buffer }
        if name == "prop" { inProperties = false }
        if name == "propstat" {
            if status.split(separator: " ").dropFirst().first.flatMap({ Int($0) }).map({ (200..<300).contains($0) }) == true {
                response.properties.merge(props) { _, new in new }; response.folder = response.folder || folder
                response.successful = true
            }
            inPropstat = false
        }
        if name == "response", !response.href.isEmpty { responses.append(response) }
        buffer = ""
    }
}
