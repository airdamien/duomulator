import XCTest
@testable import Duomulator

/// BIOS files: recognising imports, and installing / removing them under the core's name.
final class BIOSTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appending(path: "BIOSTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temp)
        super.tearDown()
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = temp.appending(path: name)
        try data.write(to: url)
        return url
    }

    func testSlotNamesAreUnique() {
        let names = BIOSCatalog.allSlots.map(\.fileName)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testIdentifiesByExactNameIgnoringCase() throws {
        XCTAssertEqual(BIOSCatalog.identify(try file("SCPH1001.BIN", Data([1, 2, 3])))?.fileName, "scph1001.bin")
        XCTAssertEqual(BIOSCatalog.identify(try file("neogeo.zip", Data([4])))?.system, .neoGeo)
    }

    func testIdentifiesDSFirmwareBySize() throws {
        let slot = BIOSCatalog.identify(try file("NDS Firmware (USA).bin", Data(count: 262_144)))
        XCTAssertEqual(slot?.fileName, "firmware.bin")
    }

    func testUnknownFileIsNotIdentified() throws {
        XCTAssertNil(BIOSCatalog.identify(try file("Sega CD BIOS (USA).bin", Data(count: 128))))
        let report = BIOSCatalog.importFiles([try file("readme.txt", Data("hi".utf8))])
        XCTAssertTrue(report.installed.isEmpty)
        XCTAssertEqual(report.failed, ["readme.txt"])
    }

    func testInstallReplacesAndRemoves() throws {
        let slot = BIOSSlot(system: .psx, title: "Test", fileName: "duomulator-test-\(UUID().uuidString).bin",
                            folder: .system, md5: [])
        defer { try? FileManager.default.removeItem(at: slot.url) }
        XCTAssertFalse(slot.isInstalled)
        try BIOSCatalog.install(try file("a.bin", Data([1])), into: slot)
        XCTAssertEqual(try Data(contentsOf: slot.url), Data([1]))
        try BIOSCatalog.install(try file("b.bin", Data([2, 2])), into: slot)
        XCTAssertEqual(try Data(contentsOf: slot.url), Data([2, 2]))
        try BIOSCatalog.remove(slot)
        XCTAssertFalse(slot.isInstalled)
    }
}
