//
//  DataPrefix.swift
//  Exhaust
//

/// Magic byte sequences for common binary file formats.
///
/// Use these with ``ReflectiveGenerator/data(prefix:)`` to generate `Data` values that a program will recognize as a specific format:
///
/// ```swift
/// let gen = #gen(.data(prefix: .png, length: 1024))
/// ```
///
/// For formats not listed here, pass a raw byte array:
///
/// ```swift
/// let gen = #gen(.data(prefix: [0xCA, 0xFE, 0xBA, 0xBE]))
/// ```
public extension [UInt8] {
    // MARK: - Images

    /// PNG signature (`89 50 4E 47 0D 0A 1A 0A`).
    static var png: [UInt8] {
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    }

    /// JPEG start-of-image marker (`FF D8 FF`).
    static var jpeg: [UInt8] {
        [0xFF, 0xD8, 0xFF]
    }

    /// GIF89a signature (`47 49 46 38 39 61`).
    static var gif: [UInt8] {
        [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]
    }

    /// BMP header (`42 4D`).
    static var bmp: [UInt8] {
        [0x42, 0x4D]
    }

    /// TIFF little-endian signature (`49 49 2A 00`).
    static var tiff: [UInt8] {
        [0x49, 0x49, 0x2A, 0x00]
    }

    /// WebP container (RIFF + WEBP). Size bytes are zero-filled.
    static var webp: [UInt8] {
        [0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50]
    }

    // MARK: - Documents

    /// PDF signature (`%PDF-`).
    static var pdf: [UInt8] {
        [0x25, 0x50, 0x44, 0x46, 0x2D]
    }

    /// ZIP local file header (`50 4B 03 04`).
    static var zip: [UInt8] {
        [0x50, 0x4B, 0x03, 0x04]
    }

    /// GZIP signature (`1F 8B`).
    static var gzip: [UInt8] {
        [0x1F, 0x8B]
    }

    // MARK: - Audio

    /// MP3 ID3v2 tag header (`49 44 33`).
    static var mp3: [UInt8] {
        [0x49, 0x44, 0x33]
    }

    /// WAV container (RIFF + WAVE). Size bytes are zero-filled.
    static var wav: [UInt8] {
        [0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45]
    }

    /// MIDI header (`4D 54 68 64`).
    static var midi: [UInt8] {
        [0x4D, 0x54, 0x68, 0x64]
    }

    /// FLAC signature (`66 4C 61 43`).
    static var flac: [UInt8] {
        [0x66, 0x4C, 0x61, 0x43]
    }

    /// Ogg container signature (`4F 67 67 53`).
    static var ogg: [UInt8] {
        [0x4F, 0x67, 0x67, 0x53]
    }

    // MARK: - Video

    /// MP4 ftyp box header (`00 00 00 1C 66 74 79 70`).
    static var mp4: [UInt8] {
        [0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70]
    }

    /// AVI container (RIFF + AVI). Size bytes are zero-filled.
    static var avi: [UInt8] {
        [0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x41, 0x56, 0x49, 0x20]
    }

    /// Matroska/WebM EBML header (`1A 45 DF A3`).
    static var mkv: [UInt8] {
        [0x1A, 0x45, 0xDF, 0xA3]
    }
}
