import SwiftUI

/// Settings > Acknowledgements: every third-party component built into the app, its
/// license, where its source lives, and the full license text (bundled under Licenses/).
struct AcknowledgementsView: View {
    struct Component: Identifiable {
        let name: String
        let use: String
        let license: String
        let source: String
        /// Bundled license text (Licenses/<file>.txt); nil when the license is only named.
        let file: String?
        var id: String { name }
    }

    static let cores: [Component] = [
        .init(name: "snes9x", use: "SNES", license: "snes9x license (non-commercial)",
              source: "https://github.com/snes9xgit/snes9x", file: "snes9x"),
        .init(name: "FCEUmm", use: "NES", license: "GPL-2.0-or-later",
              source: "https://github.com/libretro/libretro-fceumm", file: "FCEUmm"),
        .init(name: "melonDS", use: "Nintendo DS", license: "GPL-3.0-or-later",
              source: "https://github.com/libretro/melonDS", file: "melonDS"),
        .init(name: "PicoDrive", use: "Genesis, 32X, Sega CD", license: "PicoDrive license (non-commercial)",
              source: "https://github.com/libretro/picodrive", file: "PicoDrive"),
        .init(name: "FinalBurn Neo", use: "Arcade", license: "FinalBurn Neo license (non-commercial), MAME license",
              source: "https://github.com/libretro/FBNeo", file: "FinalBurn Neo"),
        .init(name: "PCSX ReARMed", use: "PlayStation", license: "GPL-2.0-or-later",
              source: "https://github.com/libretro/pcsx_rearmed", file: "PCSX ReARMed"),
        .init(name: "Mupen64Plus-Next", use: "Nintendo 64", license: "GPL-2.0-or-later",
              source: "https://github.com/libretro/mupen64plus-libretro-nx", file: "Mupen64Plus-Next"),
        .init(name: "GLideN64", use: "Nintendo 64 graphics", license: "GPL-2.0",
              source: "https://github.com/gonetz/GLideN64", file: "GLideN64"),
    ]

    static let libraries: [Component] = [
        .init(name: "Mupen64Plus RSP HLE", use: "Nintendo 64", license: "GPL-2.0",
              source: "https://github.com/mupen64plus/mupen64plus-rsp-hle", file: "RSP HLE"),
        .init(name: "RSP (cxd4)", use: "Nintendo 64", license: "CC0-1.0",
              source: "https://github.com/cxd4/rsp", file: "RSP (cxd4)"),
        .init(name: "FreeBIOS", use: "DS BIOS replacement", license: "BSD-2-Clause",
              source: "https://github.com/melonDS-emu/melonDS/tree/master/freebios", file: "FreeBIOS"),
        .init(name: "teakra", use: "DSi DSP", license: "MIT", source: "https://github.com/wwylele/teakra",
              file: "teakra"),
        .init(name: "FatFs", use: "DS", license: "FatFs license (BSD-1-Clause style)",
              source: "http://elm-chan.org/fsw/ff/", file: "FatFs"),
        .init(name: "tiny-AES-c", use: "DSi", license: "The Unlicense", source: "https://github.com/kokke/tiny-AES-c",
              file: "tiny-AES-c"),
        .init(name: "libchdr", use: "CHD disc images", license: "BSD-3-Clause",
              source: "https://github.com/rtissera/libchdr", file: "libchdr"),
        .init(name: "LZMA SDK", use: "7z and CHD decompression", license: "Public domain",
              source: "https://www.7-zip.org/sdk.html", file: "LZMA SDK"),
        .init(name: "Zstandard", use: "CHD decompression", license: "BSD-3-Clause",
              source: "https://github.com/facebook/zstd", file: nil),
        .init(name: "zlib", use: "Compression", license: "zlib", source: "https://zlib.net", file: "zlib"),
        .init(name: "libpng", use: "N64 texture packs", license: "libpng license",
              source: "http://www.libpng.org/pub/png/libpng.html", file: "libpng"),
        .init(name: "xxHash", use: "Hashing", license: "BSD-2-Clause", source: "https://github.com/Cyan4973/xxHash",
              file: "xxHash"),
        .init(name: "dr_libs", use: "Arcade audio", license: "Public domain or MIT-0",
              source: "https://github.com/mackron/dr_libs", file: "dr_libs"),
        .init(name: "stb_vorbis", use: "Arcade audio", license: "Public domain or MIT",
              source: "https://github.com/nothings/stb", file: nil),
        .init(name: "r8brain-free-src", use: "Arcade audio resampling", license: "MIT",
              source: "https://github.com/avaneev/r8brain-free-src", file: nil),
        .init(name: "libretro-common", use: "Core support code", license: "MIT",
              source: "https://github.com/libretro/libretro-common", file: nil),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.cores) { ComponentRow(component: $0) }
            } header: {
                Text("Emulation Cores")
            } footer: {
                Text("Source code for these cores, including the exact versions and changes used here, is available at the links above. Duomulator is free and not sold; the non-commercial licenses don't allow it to be.")
            }
            Section("Libraries") {
                ForEach(Self.libraries) { ComponentRow(component: $0) }
            }
            Section {
                Text("Nintendo, Super Nintendo, Nintendo 64 and Nintendo DS are trademarks of Nintendo. Sega, Genesis, Mega Drive, 32X and Sega CD are trademarks of Sega. PlayStation is a trademark of Sony Interactive Entertainment. Neo Geo is a trademark of SNK. Duomulator isn't affiliated with or endorsed by any of them, and includes no games or BIOS files.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Acknowledgements")
    }
}

private struct ComponentRow: View {
    let component: AcknowledgementsView.Component

    var body: some View {
        NavigationLink {
            LicenseTextView(component: component)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(component.name)
                Text("\(component.use) · \(component.license)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LicenseTextView: View {
    let component: AcknowledgementsView.Component

    private var text: String {
        guard let file = component.file,
              let url = Bundle.main.url(forResource: file, withExtension: "txt", subdirectory: "Licenses")
                ?? Bundle.main.url(forResource: file, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
                ?? String(contentsOf: url, encoding: .isoLatin1)
        else { return "Licensed under \(component.license). See \(component.source) for the full text." }
        return text
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let url = URL(string: component.source) {
                    Link(component.source, destination: url).font(.footnote)
                }
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(component.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
