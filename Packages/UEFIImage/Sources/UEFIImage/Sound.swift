import Foundation
import Localization

/// A sound kept in a firmware image: a WAV file, as ASUS keeps the sound its
/// boards play on POST — the whole body of a Freeform file, where a body of
/// sections would be (`UEFI_IMAGE_FORMAT.md` §9).
///
/// Recognised by its opening and taken only when its chunks read through to
/// the format chunk and the data, which is also where its length and what
/// it plays come from.
public struct Sound: Equatable, Sendable {
    public var range: Range<UInt64>
    /// The format chunk's `wFormatTag`: `1` is PCM.
    public var encoding: UInt16
    public var channels: UInt16
    public var sampleRate: UInt32
    public var bitsPerSample: UInt16
    /// The data chunk's length, in bytes.
    public var dataLength: UInt32
    /// Bytes per second, as the format chunk states it.
    public var byteRate: UInt32

    public init(range: Range<UInt64>, encoding: UInt16, channels: UInt16, sampleRate: UInt32,
                bitsPerSample: UInt16, dataLength: UInt32, byteRate: UInt32) {
        self.range = range
        self.encoding = encoding
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitsPerSample = bitsPerSample
        self.dataLength = dataLength
        self.byteRate = byteRate
    }

    /// The encodings a firmware's WAV is likely to use, by the names RIFF
    /// gives them; any other keeps its number.
    public var encodingName: String {
        switch encoding {
        case 0x0001: return "PCM"
        case 0x0002: return "ADPCM"
        case 0x0003: return "IEEE float"
        case 0x0006: return "A-law"
        case 0x0007: return "µ-law"
        case 0x0011: return "IMA ADPCM"
        case 0xFFFE: return "Extensible"
        default: return String(format: "0x%04X", encoding)
        }
    }

    /// How long it plays, in seconds; nil when the format chunk states no rate.
    public var duration: Double? {
        byteRate == 0 ? nil : Double(dataLength) / Double(byteRate)
    }

    /// The format and the sample rate, in the words of the language running.
    public var name: String {
        switch channels {
        case 1: return L("WAV, %1$@ Hz, mono", "\(sampleRate)")
        case 2: return L("WAV, %1$@ Hz, stereo", "\(sampleRate)")
        default: return L("WAV, %1$@ Hz, %2$@ channels", "\(sampleRate)", "\(channels)")
        }
    }

    /// RIFF's chunk ids, as the scan reads a dword.
    static let riff: UInt32 = 0x4646_4952          // "RIFF"
    static let wave: UInt32 = 0x4556_4157          // "WAVE"
    static let format: UInt32 = 0x2074_6D66        // "fmt "
    static let data: UInt32 = 0x6174_6164          // "data"
    static let maxChunks = 64

    /// The WAV file starting at `start` and ending at or before `limit`, or nil
    /// when what is there is not one: a RIFF header naming `WAVE`, and a
    /// format chunk and a data chunk among the chunks it holds, each whole.
    /// A RIFF size claiming more than is there ends the file where the bytes
    /// do: the G733PYV's says four bytes more than its file holds, its data
    /// chunk whole before them.
    public static func read(at start: UInt64, limit: UInt64, in reader: ImageReader) -> Sound? {
        guard reader.uint32(at: start) == riff, reader.uint32(at: start + 8) == wave,
              let riffSize = reader.uint32(at: start + 4), riffSize >= 4
        else { return nil }
        // A chunk's data is padded to an even length, and so is the file.
        let end = min(start + 8 + UInt64(riffSize) + UInt64(riffSize & 1), limit, reader.count)
        guard end >= start + 12 else { return nil }

        var formatChunk: (encoding: UInt16, channels: UInt16, rate: UInt32, byteRate: UInt32, bits: UInt16)?
        var dataLength: UInt32?
        var at = start + 12
        for _ in 0..<maxChunks where at + 8 <= end {
            guard let id = reader.uint32(at: at), let size = reader.uint32(at: at + 4) else { return nil }
            let body = at + 8
            guard body + UInt64(size) <= end else { return nil }
            if id == format, size >= 16,
               let encoding = reader.uint16(at: body), let channels = reader.uint16(at: body + 2),
               let rate = reader.uint32(at: body + 4), let byteRate = reader.uint32(at: body + 8),
               let bits = reader.uint16(at: body + 14) {
                formatChunk = (encoding, channels, rate, byteRate, bits)
            } else if id == data {
                dataLength = size
            }
            at = body + UInt64(size) + UInt64(size & 1)
        }
        guard let formatChunk, let dataLength, formatChunk.channels > 0, formatChunk.rate > 0 else { return nil }
        return Sound(
            range: start..<end, encoding: formatChunk.encoding, channels: formatChunk.channels,
            sampleRate: formatChunk.rate, bitsPerSample: formatChunk.bits, dataLength: dataLength,
            byteRate: formatChunk.byteRate
        )
    }
}

extension Parser {
    /// A sound at `offset`, as a row of its own; nil when there is none.
    func parseSound(at offset: UInt64, limit: UInt64) -> UEFINode? {
        Sound.read(at: offset, limit: limit, in: reader).map { sound in
            UEFINode(
                kind: .sound,
                name: sound.name,
                header: sound.range.lowerBound..<sound.range.lowerBound,
                body: sound.range
            )
        }
    }
}
