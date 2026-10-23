import Foundation
import Compression

/// Minimal read-only ZIP support, just enough to pull a ROM out of the `.zip` files ROM sets
/// usually ship as. Handles "stored" and "deflate" entries (the only methods real ROM zips
/// use) via the system libcompression, whose COMPRESSION_ZLIB is raw deflate — exactly what
/// ZIP stores. No ZIP64, no encryption, no multi-disk archives; those fail with a clear error.
enum ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let flags: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    /// The largest cartridge any core takes (a 4 Gbit DS card; N64 tops out at 64 MB). Still
    /// guards against zip bombs.
    static let maxEntrySize = 512 * 1024 * 1024

    /// Extensions we treat as ROMs (any system) inside an archive.
    static let romExtensions: Set<String> = GamePaths.romExtensions.subtracting(["zip"])

    /// Returns the name and bytes of the first ROM in the archive. Entries are tried in central
    /// directory order; macOS resource-fork junk (`__MACOSX/`, `._*`) is skipped.
    static func extractFirstROM(from archive: [UInt8]) throws -> (name: String, data: Data) {
        let entries = try readEntries(archive)
        guard let entry = entries.first(where: isROMEntry) else {
            throw EmulatorError.unsupportedArchive("The zip doesn't contain a SNES or NES ROM.")
        }
        return (entry.name, try extract(entry, from: archive))
    }

    static func isROMEntry(_ entry: Entry) -> Bool {
        guard !entry.isDirectory else { return false }
        let fileName = entry.name.split(separator: "/").last.map(String.init) ?? entry.name
        if entry.name.hasPrefix("__MACOSX/") || fileName.hasPrefix("._") { return false }
        let ext = (fileName as NSString).pathExtension.lowercased()
        return romExtensions.contains(ext)
    }

    // MARK: - Central directory

    static func readEntries(_ zip: [UInt8]) throws -> [Entry] {
        // The end-of-central-directory record is the last 22 bytes plus an optional comment
        // of up to 64 KB, so scan backwards for its signature.
        let eocdSize = 22
        guard zip.count >= eocdSize else { throw corrupt("file too small") }
        var eocd = -1
        var i = zip.count - eocdSize
        let lowest = max(0, zip.count - eocdSize - 0xFFFF)
        while i >= lowest {
            if u32(zip, i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw corrupt("no end-of-directory record") }

        let entryCount = Int(u16(zip, eocd + 10))
        let directorySize = Int(u32(zip, eocd + 12))
        let directoryOffset = Int(u32(zip, eocd + 16))
        if entryCount == 0xFFFF || directoryOffset == 0xFFFF_FFFF {
            throw EmulatorError.unsupportedArchive("ZIP64 archives aren't supported; re-zip the ROM normally.")
        }
        guard directoryOffset + directorySize <= eocd else { throw corrupt("bad directory offset") }

        var entries: [Entry] = []
        var p = directoryOffset
        for _ in 0..<entryCount {
            guard p + 46 <= zip.count, u32(zip, p) == 0x0201_4B50 else {
                throw corrupt("bad directory entry")
            }
            let nameLength = Int(u16(zip, p + 28))
            let extraLength = Int(u16(zip, p + 30))
            let commentLength = Int(u16(zip, p + 32))
            guard p + 46 + nameLength <= zip.count else { throw corrupt("truncated file name") }
            let nameBytes = zip[(p + 46)..<(p + 46 + nameLength)]
            // Bit 11 = UTF-8 names; otherwise CP437, which is ASCII for every name that matters.
            let name = String(decoding: nameBytes, as: UTF8.self)
            entries.append(Entry(
                name: name,
                method: u16(zip, p + 10),
                flags: u16(zip, p + 8),
                crc32: u32(zip, p + 16),
                compressedSize: Int(u32(zip, p + 20)),
                uncompressedSize: Int(u32(zip, p + 24)),
                localHeaderOffset: Int(u32(zip, p + 42))))
            p += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    // MARK: - Entry data

    static func extract(_ entry: Entry, from zip: [UInt8]) throws -> Data {
        if entry.flags & 0x1 != 0 {
            throw EmulatorError.unsupportedArchive("Password-protected zips aren't supported.")
        }
        guard entry.uncompressedSize > 0, entry.uncompressedSize <= maxEntrySize else {
            throw corrupt("\(entry.name) has an implausible size")
        }

        // Sizes come from the central directory, which is authoritative even when the local
        // header defers them to a trailing data descriptor (flag bit 3).
        let h = entry.localHeaderOffset
        guard h + 30 <= zip.count, u32(zip, h) == 0x0403_4B50 else { throw corrupt("bad local header") }
        let start = h + 30 + Int(u16(zip, h + 26)) + Int(u16(zip, h + 28))
        guard start + entry.compressedSize <= zip.count else { throw corrupt("truncated entry data") }

        var out = [UInt8](repeating: 0, count: entry.uncompressedSize)
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else { throw corrupt("stored size mismatch") }
            out.replaceSubrange(0..<out.count, with: zip[start..<(start + entry.compressedSize)])
        case 8:
            let written = zip.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    compression_decode_buffer(dst.baseAddress!, dst.count,
                                              src.baseAddress! + start, entry.compressedSize,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.uncompressedSize else { throw corrupt("deflate stream is damaged") }
        default:
            throw EmulatorError.unsupportedArchive(
                "\(entry.name) uses ZIP compression method \(entry.method); only stored/deflate are supported.")
        }

        guard crc32(out) == entry.crc32 else { throw corrupt("CRC mismatch in \(entry.name)") }
        return Data(out)
    }

    // MARK: - Helpers

    private static func corrupt(_ detail: String) -> EmulatorError {
        .unsupportedArchive("The zip looks damaged (\(detail)).")
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        guard i >= 0, i + 2 <= b.count else { return 0 }
        return UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// Standard CRC-32 (IEEE 802.3), as stored in ZIP headers.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        crcTable.withUnsafeBufferPointer { table in
            for byte in bytes { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}
