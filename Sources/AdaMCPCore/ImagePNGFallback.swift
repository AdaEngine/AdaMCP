#if !(canImport(CoreGraphics) && canImport(ImageIO))
import AdaEngine
import Foundation

private enum AdaMCPPNGEncodingError: LocalizedError {
    case unsupportedFormat(Image.Format)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            "Unsupported image format for PNG encoding: \(format)"
        }
    }
}

public extension Image {
    func writePNG(to url: URL) throws {
        let data = try self.adamcpPNGData()
        try data.write(to: url, options: .atomic)
    }

    private func adamcpPNGData() throws -> Data {
        let rgbaData = try self.adamcpRGBAData()
        var scanlines = Data(capacity: (width * 4 + 1) * height)
        for row in 0..<height {
            scanlines.append(0)
            let start = row * width * 4
            scanlines.append(rgbaData.subdata(in: start..<(start + width * 4)))
        }

        var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        png.append(Self.adamcpPNGChunk(type: "IHDR", data: Self.adamcpIHDR(width: width, height: height)))
        png.append(Self.adamcpPNGChunk(type: "IDAT", data: Self.adamcpZlibStoredData(scanlines)))
        png.append(Self.adamcpPNGChunk(type: "IEND", data: Data()))
        return png
    }

    private func adamcpRGBAData() throws -> Data {
        switch format {
        case .rgba8:
            return data
        case .bgra8, .bgra8_sRGB:
            var result = data
            result.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                for offset in stride(from: 0, to: bytes.count, by: 4) {
                    let blue = base[offset]
                    base[offset] = base[offset + 2]
                    base[offset + 2] = blue
                }
            }
            return result
        case .rgb8:
            var result = Data(capacity: width * height * 4)
            for offset in stride(from: 0, to: data.count, by: 3) {
                result.append(data[offset])
                result.append(data[offset + 1])
                result.append(data[offset + 2])
                result.append(255)
            }
            return result
        case .gray:
            var result = Data(capacity: width * height * 4)
            for value in data {
                result.append(value)
                result.append(value)
                result.append(value)
                result.append(255)
            }
            return result
        }
    }

    private static func adamcpIHDR(width: Int, height: Int) -> Data {
        var data = Data()
        data.appendUInt32BE(UInt32(width))
        data.appendUInt32BE(UInt32(height))
        data.append(contentsOf: [8, 6, 0, 0, 0])
        return data
    }

    private static func adamcpPNGChunk(type: String, data: Data) -> Data {
        var chunk = Data()
        chunk.appendUInt32BE(UInt32(data.count))
        let typeData = Data(type.utf8)
        chunk.append(typeData)
        chunk.append(data)

        var crcInput = Data()
        crcInput.append(typeData)
        crcInput.append(data)
        chunk.appendUInt32BE(crcInput.crc32())
        return chunk
    }

    private static func adamcpZlibStoredData(_ data: Data) -> Data {
        var result = Data([0x78, 0x01])
        var offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            let length = min(remaining, 65_535)
            let isFinal = offset + length == data.count
            result.append(isFinal ? 0x01 : 0x00)
            let len = UInt16(length)
            let nlen = ~len
            result.append(UInt8(len & 0xff))
            result.append(UInt8((len >> 8) & 0xff))
            result.append(UInt8(nlen & 0xff))
            result.append(UInt8((nlen >> 8) & 0xff))
            result.append(data.subdata(in: offset..<(offset + length)))
            offset += length
        }
        result.appendUInt32BE(data.adler32())
        return result
    }
}

private extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    func adler32() -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in self {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return (b << 16) | a
    }

    func crc32() -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in self {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = 0 &- (crc & 1)
                crc = (crc >> 1) ^ (0xedb8_8320 & mask)
            }
        }
        return ~crc
    }
}
#endif
