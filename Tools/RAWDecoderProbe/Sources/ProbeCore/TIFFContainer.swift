import Foundation

public enum ProbeError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let text): return text } }
}

/// Read-only classic TIFF parser. Only whitelisted numeric technical tags are exposed.
/// All offsets/counts are bounded; SubIFD traversal rejects cycles and excessive directories.
public struct TIFFContainer {
    public struct Directory {
        public let offset: Int
        public let tags: [Int: [Int]]
    }
    public let data: Data
    private let little: Bool
    public let directories: [Directory]
    public var orientation: Int { directories.first?.tags[274]?.first ?? 1 }
    public var rawDirectory: Directory? {
        directories.first { $0.tags[262]?.first == 32803 && $0.tags[256]?.first != nil && $0.tags[257]?.first != nil }
    }

    public init(data: Data) throws {
        guard data.count >= 8 else { throw ProbeError.invalid("Truncated TIFF header") }
        guard data.prefix(2) == Data([73,73]) || data.prefix(2) == Data([77,77]) else {
            throw ProbeError.invalid("Unsupported container: expected classic TIFF")
        }
        let little = data[0] == 73
        func number(_ offset: Int, _ size: Int) throws -> Int {
            guard offset >= 0, size <= data.count, offset <= data.count-size else { throw ProbeError.invalid("TIFF offset out of bounds") }
            var result = 0
            for i in 0..<size { result |= Int(data[offset+i]) << (8 * (little ? i : size-1-i)) }
            return result
        }
        guard try number(2,2) == 42 else { throw ProbeError.invalid("Unsupported TIFF version") }
        let allowed: Set<Int> = [256,257,258,259,262,273,274,277,278,279,330,513,514]
        var queue = [try number(4,4)], visited = Set<Int>(), dirs: [Directory] = []
        while !queue.isEmpty {
            let offset = queue.removeFirst()
            if offset == 0 { continue }
            guard visited.insert(offset).inserted else { throw ProbeError.invalid("Cyclic TIFF directories") }
            guard visited.count <= 64 else { throw ProbeError.invalid("Too many TIFF directories") }
            let count = try number(offset,2)
            guard count <= 4096 else { throw ProbeError.invalid("Excessive TIFF tag count") }
            _ = try number(offset+2+count*12,4)
            var tags: [Int: [Int]] = [:]
            for i in 0..<count {
                let entry = offset+2+i*12, tag = try number(entry,2)
                guard allowed.contains(tag) else { continue }
                let type = try number(entry+2,2), n = try number(entry+4,4)
                guard let size = [1:1,3:2,4:4][type] else { continue }
                guard n <= 65536 else { throw ProbeError.invalid("Excessive TIFF value count") }
                let valueOffset = n*size <= 4 ? entry+8 : try number(entry+8,4)
                guard valueOffset <= data.count, n*size <= data.count-valueOffset else { throw ProbeError.invalid("TIFF values out of bounds") }
                tags[tag] = try (0..<n).map { try number(valueOffset+$0*size,size) }
            }
            dirs.append(Directory(offset:offset,tags:tags))
            queue.append(contentsOf:tags[330] ?? [])
            queue.append(try number(offset+2+count*12,4))
        }
        self.data = data; self.little = little; self.directories = dirs
    }

    public func embeddedJPEGs() throws -> [Data] {
        try directories.compactMap { dir in
            guard let offset = dir.tags[513]?.first, let count = dir.tags[514]?.first else { return nil }
            guard offset >= 0, count >= 4, offset <= data.count, count <= data.count-offset else {
                throw ProbeError.invalid("Embedded JPEG range out of bounds")
            }
            guard data[offset] == 255, data[offset+1] == 216,
                  data[offset+count-2] == 255, data[offset+count-1] == 217 else {
                throw ProbeError.invalid("Embedded JPEG lacks SOI/EOI markers")
            }
            return data.subdata(in:offset..<offset+count)
        }
    }
}
