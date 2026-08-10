import Foundation

/// 够用就好的只读 zip:**按名字取出一个条目**,别的一概不做。
///
/// 存在的唯一理由是 docx——它就是一个 zip,正文在 `word/document.xml` 里。iOS 没有公开的
/// zip API(`NSFileWrapper` 认的是 rtfd 那种目录包),而为了读一个文件引一整个压缩库,
/// 是拿一份长期依赖换二百行确定的格式解析。
///
/// 不支持 zip64 和加密:一份体检报告不会有四十亿字节,也不会带密码。碰上就照实报错,
/// 不猜——猜错的结果是把一段二进制当成正文发给模型。
enum ZIPArchive {

    enum Failure: LocalizedError {
        case notAnArchive
        case entryNotFound(String)
        case unsupported(String)
        case corrupt

        var errorDescription: String? {
            switch self {
            case .notAnArchive: "这个文件不是有效的 Word 文档。"
            case .entryNotFound: "这份文档里没有找到正文。"
            case .unsupported(let why): "读不了这份文档（\(why)）。"
            case .corrupt: "这份文档已经损坏，读不出来。"
            }
        }
    }

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    private static let centralDirectorySignature: UInt32 = 0x0201_4b50
    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    /// zip 里表示「这个数放不下了,去 zip64 的扩展字段里拿」的哨兵值。
    private static let zip64Sentinel: UInt32 = 0xFFFF_FFFF

    static func entry(named name: String, in data: Data) throws -> Data {
        let bytes = [UInt8](data)
        let directory = try centralDirectoryStart(in: bytes)

        var cursor = directory.offset
        for _ in 0..<directory.entryCount {
            guard try u32(bytes, cursor) == centralDirectorySignature else { throw Failure.corrupt }
            let method = try u16(bytes, cursor + 10)
            let compressedSize = try Int(u32(bytes, cursor + 20))
            let nameLength = try Int(u16(bytes, cursor + 28))
            let extraLength = try Int(u16(bytes, cursor + 30))
            let commentLength = try Int(u16(bytes, cursor + 32))
            let localOffset = try Int(u32(bytes, cursor + 42))
            let entryName = try string(bytes, at: cursor + 46, length: nameLength)

            if entryName == name {
                guard compressedSize != Int(zip64Sentinel), localOffset != Int(zip64Sentinel) else {
                    throw Failure.unsupported("zip64")
                }
                return try payload(
                    bytes,
                    localHeaderOffset: localOffset,
                    compressedSize: compressedSize,
                    method: method
                )
            }
            cursor += 46 + nameLength + extraLength + commentLength
        }
        throw Failure.entryNotFound(name)
    }

    // MARK: - 目录

    private static func centralDirectoryStart(in bytes: [UInt8]) throws -> (offset: Int, entryCount: Int) {
        // 结尾那条记录后面可能还跟着一段注释,所以从尾巴往前找签名。注释最长 65535。
        let minimum = 22
        guard bytes.count >= minimum else { throw Failure.notAnArchive }
        let lowest = max(0, bytes.count - minimum - 65_535)

        var index = bytes.count - minimum
        while index >= lowest {
            if peekU32(bytes, index) == endOfCentralDirectorySignature {
                let count = try Int(u16(bytes, index + 10))
                let offset = try Int(u32(bytes, index + 16))
                guard offset != Int(zip64Sentinel) else { throw Failure.unsupported("zip64") }
                guard offset >= 0, offset < bytes.count else { throw Failure.corrupt }
                return (offset, count)
            }
            index -= 1
        }
        throw Failure.notAnArchive
    }

    /// 中央目录记的是**这一条在文件里的起点**,而真正的数据要跨过本地头才开始——本地头里
    /// 那两个长度和中央目录里的可以不一样,所以必须照本地头这一份算。
    private static func payload(
        _ bytes: [UInt8],
        localHeaderOffset: Int,
        compressedSize: Int,
        method: UInt16
    ) throws -> Data {
        guard try u32(bytes, localHeaderOffset) == localHeaderSignature else { throw Failure.corrupt }
        let nameLength = try Int(u16(bytes, localHeaderOffset + 26))
        let extraLength = try Int(u16(bytes, localHeaderOffset + 28))
        let start = localHeaderOffset + 30 + nameLength + extraLength
        let end = start + compressedSize
        guard start >= 0, end <= bytes.count, start <= end else { throw Failure.corrupt }

        let stored = Data(bytes[start..<end])
        switch method {
        case 0:
            return stored
        case 8:
            // zip 里存的是**裸 deflate**(没有 zlib 头),正好是 Apple 这个常量的含义。
            guard let inflated = try? (stored as NSData).decompressed(using: .zlib) else {
                throw Failure.corrupt
            }
            return inflated as Data
        default:
            throw Failure.unsupported("压缩方式 \(method)")
        }
    }

    // MARK: - 小端读数

    private static func u16(_ bytes: [UInt8], _ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { throw Failure.corrupt }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { throw Failure.corrupt }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    /// 倒着找签名时越界只意味着「不是这条」,不值得在那儿写一次 try。
    private static func peekU32(_ bytes: [UInt8], _ offset: Int) -> UInt32? {
        try? u32(bytes, offset)
    }

    private static func string(_ bytes: [UInt8], at offset: Int, length: Int) throws -> String {
        guard offset >= 0, length >= 0, offset + length <= bytes.count else { throw Failure.corrupt }
        return String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
    }
}
