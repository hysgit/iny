import Foundation
import CoreText

enum FontLibrary {
    static var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Fonts") }
    static func registerAll() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
    }
    static func importFont(_ url: URL) throws -> String {
        guard ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()) else { throw AppError.message("请选择 TTF、OTF 或 TTC 字体。") }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
        try FileManager.default.copyItem(at: url, to: target)
        guard CTFontManagerRegisterFontsForURL(target as CFURL, .process, nil),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(target as CFURL) as? [CTFontDescriptor], let first = descriptors.first,
              let family = CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String else {
            try? FileManager.default.removeItem(at: target); throw AppError.message("字体文件无法加载。")
        }
        return family
    }
}
