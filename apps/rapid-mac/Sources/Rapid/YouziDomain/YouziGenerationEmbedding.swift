import Foundation

/// Additive container metadata only: IDAT, PCM samples and MP4 media/offsets
/// remain byte-for-byte intact. Unknown blocks are preserved. Bounded parsing
/// rejects malformed files before writing. No codec or audio time transforms.
enum YouziGenerationEmbedding {
    enum Failure: Error { case unsupported, malformed, tooLarge }
    static let limit = 256 * 1024
    private static let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    private static let textPrefix = Data("YouziGeneration\0\0\0\0\0".utf8)
    // Private UUID box, deliberately independent of Apple/ISO registered tags.
    private static let uuid = Data([0x6d,0x7f,0x65,0x5b,0xc7,0xf7,0x47,0xab,0xa9,0x61,0x6c,0xfa,0x50,0x6e,0x3d,0xd1])

    static func embed(_ record: YouziArtifactGeneration, in data: Data, kind: YouziArtifactKind) throws -> Data {
        if try read(data, kind: kind) == record { return data }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(record)
        guard payload.count <= limit else { throw Failure.tooLarge }
        return try transform(data, kind: kind, payload: payload).data
    }

    static func read(_ data: Data, kind: YouziArtifactKind) throws -> YouziArtifactGeneration? {
        guard let payload = try transform(data, kind: kind, payload: nil).payload else { return nil }
        guard payload.count <= limit else { throw Failure.tooLarge }
        let record = try JSONDecoder().decode(YouziArtifactGeneration.self, from: payload)
        guard record.version == 1 else { throw Failure.unsupported }
        return record
    }

    private static func transform(_ data: Data, kind: YouziArtifactKind, payload: Data?) throws -> (data: Data, payload: Data?) {
        switch kind {
        case .image: return try png(data, payload)
        case .audio: return try wav(data, payload)
        case .video: return try mp4(data, payload)
        default: throw Failure.unsupported
        }
    }

    private static func uint32(_ data: Data, _ offset: Int, little: Bool = false) -> Int {
        let bytes = data[offset..<offset+4]
        return (little ? Array(bytes.reversed()) : Array(bytes)).reduce(0) { ($0 << 8) | Int($1) }
    }
    private static func word(_ value: Int, little: Bool = false) -> Data {
        let result = (0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        return Data(little ? result.reversed() : result)
    }
    private static func tag(_ data: Data, _ offset: Int) -> String {
        String(decoding: data[offset..<offset+4], as: UTF8.self)
    }
    private static func crc(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffffffff
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb88320 : value >> 1 }
        }
        return value ^ 0xffffffff
    }
    private static func pngChunk(_ type: String, _ payload: Data) -> Data {
        let body = Data(type.utf8) + payload
        return word(payload.count) + body + word(Int(crc(body)))
    }
    private static func png(_ data: Data, _ payload: Data?) throws -> (Data, Data?) {
        guard data.starts(with: pngSignature) else { throw Failure.malformed }
        var cursor = 8; var output = pngSignature; var found: Data?
        while cursor + 12 <= data.count {
            let count = uint32(data, cursor), type = tag(data, cursor+4)
            guard count <= data.count-cursor-12 else { throw Failure.malformed }
            let end = cursor+count+12
            let own = type == "iTXt" && data[cursor+8..<end-4].starts(with: textPrefix)
            if own {
                guard count-textPrefix.count <= limit else { throw Failure.tooLarge }
                found = Data(data[cursor+8+textPrefix.count..<end-4])
            }
            if type == "IEND" {
                guard count == 0, end == data.count else { throw Failure.malformed }
                if let payload { output += pngChunk("iTXt", textPrefix+payload) }
                output += data[cursor..<end]
                return (payload == nil ? data : output, found)
            }
            if !own || payload == nil { output += data[cursor..<end] }
            cursor = end
        }
        throw Failure.malformed
    }
    private static func wav(_ data: Data, _ payload: Data?) throws -> (Data, Data?) {
        guard data.count >= 12, tag(data,0) == "RIFF", tag(data,8) == "WAVE",
              uint32(data,4,little:true) == data.count-8 else { throw Failure.malformed }
        var cursor = 12; var output = Data(data.prefix(12)); var found: Data?
        while cursor+8 <= data.count {
            let count = uint32(data,cursor+4,little:true)
            guard count <= data.count-cursor-8 else { throw Failure.malformed }
            let end = cursor+8+count+(count % 2)
            guard end <= data.count else { throw Failure.malformed }
            let own = tag(data,cursor) == "yzgn"
            if own {
                guard count <= limit else { throw Failure.tooLarge }
                found = Data(data[cursor+8..<cursor+8+count])
            }
            if !own || payload == nil { output += data[cursor..<end] }
            cursor = end
        }
        guard cursor == data.count else { throw Failure.malformed }
        if let payload {
            output += Data("yzgn".utf8)+word(payload.count,little:true)+payload
            if payload.count % 2 == 1 { output.append(0) }
            guard output.count-8 <= Int(UInt32.max) else { throw Failure.tooLarge }
            output.replaceSubrange(4..<8,with:word(output.count-8,little:true))
        }
        return (payload == nil ? data : output, found)
    }
    private static func mp4(_ data: Data, _ payload: Data?) throws -> (Data, Data?) {
        guard data.count >= 12, tag(data,4) == "ftyp" else { throw Failure.malformed }
        var cursor = 0; var output = data; var found: Data?
        while cursor+8 <= data.count {
            let raw = uint32(data,cursor); var count = raw; var header = 8
            if raw == 1 {
                guard cursor+16 <= data.count, uint32(data,cursor+8) == 0 else { throw Failure.tooLarge }
                count = uint32(data,cursor+12); header = 16
            } else if raw == 0 { count = data.count-cursor }
            guard count >= header, count <= data.count-cursor else { throw Failure.malformed }
            if tag(data,cursor+4) == "uuid", count >= header+16,
               data[cursor+header..<cursor+header+16] == uuid {
                guard count-header-16 <= limit else { throw Failure.tooLarge }
                found = Data(data[cursor+header+16..<cursor+count])
                // Reclaim only our own box without moving any media offsets.
                if payload != nil { output.replaceSubrange(cursor+4..<cursor+8,with:Data("free".utf8)) }
            }
            if raw == 0, payload != nil {
                guard count <= Int(UInt32.max) else { throw Failure.tooLarge }
                output.replaceSubrange(cursor..<cursor+4,with:word(count))
            }
            cursor += count
        }
        guard cursor == data.count else { throw Failure.malformed }
        if let payload { output += word(payload.count+24)+Data("uuid".utf8)+uuid+payload }
        return (payload == nil ? data : output, found)
    }
}
