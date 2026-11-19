import Foundation

struct HTTPByteRange: Equatable {
    let start: Int64
    let length: Int64
    static func parse(_ header: String?, size: Int64) throws -> Self {
        guard size > 0 else { return Self(start: 0, length: 0) }
        guard let header else { return Self(start: 0, length: size) }
        guard header.hasPrefix("bytes="), !header.contains(",") else { throw AppError.message("不支持的字节范围。") }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw AppError.invalidResponse }
        if parts[0].isEmpty {
            guard let count = Int64(parts[1]), count > 0 else { throw AppError.invalidResponse }
            let length = min(count, size); return Self(start: size - length, length: length)
        }
        guard let start = Int64(parts[0]), start >= 0, start < size else { throw AppError.invalidResponse }
        let end = parts[1].isEmpty ? size - 1 : min(Int64(parts[1]) ?? -1, size - 1)
        guard end >= start else { throw AppError.invalidResponse }
        return Self(start: start, length: end - start + 1)
    }
}
