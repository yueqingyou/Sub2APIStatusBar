import CryptoKit
import Foundation
import XCTest
@testable import Sub2APIStatusCore

final class HardwareFirmwareUpdateTests: XCTestCase {
    func testVersionParsingAndComparison() {
        XCTAssertEqual(HardwareFirmwareVersion("0.7.0")?.description, "0.7.0")
        XCTAssertLessThan(
            HardwareFirmwareVersion(major: 0, minor: 7, patch: 0),
            HardwareFirmwareVersion(major: 0, minor: 7, patch: 1)
        )
        XCTAssertNil(HardwareFirmwareVersion("0.7"))
        XCTAssertNil(HardwareFirmwareVersion("0.7.0-beta"))
        XCTAssertNil(HardwareFirmwareVersion("256.0.0"))
    }

    func testBuildsStableFirmwareUpdateControlPayloads() {
        let manifest = HardwareFirmwareManifest(
            schemaVersion: 1,
            hardwareModel: HardwareFirmwarePackage.hardwareModel,
            firmwareVersion: "0.7.0",
            monitorProtocolVersion: HardwareMonitorBLEProtocol.protocolVersion,
            updateProtocolVersion: HardwareFirmwareUpdateProtocol.protocolVersion,
            fileName: "tokenrouter_monitor.bin",
            size: 3,
            sha256: String(repeating: "00", count: 32)
        )
        let package = HardwareFirmwarePackage(
            manifest: manifest,
            version: HardwareFirmwareVersion(major: 0, minor: 7, patch: 0),
            image: Data([1, 2, 3]),
            sha256: Data((0..<32).map(UInt8.init))
        )

        let start = [UInt8](HardwareFirmwareUpdateProtocol.startPayload(for: package))
        XCTAssertEqual(start.count, HardwareFirmwareUpdateProtocol.startPayloadLength)
        XCTAssertEqual(Array(start.prefix(5)), [0x54, 0x52, 0x55, 0x01, 0x01])
        XCTAssertEqual(Array(start[5..<9]), [0x03, 0x00, 0x00, 0x00])
        XCTAssertEqual(Array(start[9..<12]), [0x00, 0x07, 0x00])
        XCTAssertEqual(Array(start[12..<44]), (0..<32).map(UInt8.init))
        XCTAssertEqual(
            HardwareFirmwareUpdateProtocol.finishPayload,
            Data([0x54, 0x52, 0x55, 0x01, 0x02])
        )
        XCTAssertEqual(
            HardwareFirmwareUpdateProtocol.abortPayload,
            Data([0x54, 0x52, 0x55, 0x01, 0x03])
        )
    }

    func testLoadsAndVerifiesFirmwarePackage() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = makeFirmwareImage(version: "0.7.0")
        let digest = Data(SHA256.hash(data: image))
        let manifest = HardwareFirmwareManifest(
            schemaVersion: 1,
            hardwareModel: HardwareFirmwarePackage.hardwareModel,
            firmwareVersion: "0.7.0",
            monitorProtocolVersion: HardwareMonitorBLEProtocol.protocolVersion,
            updateProtocolVersion: HardwareFirmwareUpdateProtocol.protocolVersion,
            fileName: "tokenrouter_monitor.bin",
            size: image.count,
            sha256: digest.hexadecimal
        )
        try image.write(to: directory.appendingPathComponent(manifest.fileName))
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent(HardwareFirmwarePackageLoader.manifestFileName)
        )

        let package = try HardwareFirmwarePackageLoader().load(from: directory)
        XCTAssertEqual(package.version.description, "0.7.0")
        XCTAssertEqual(package.image, image)
        XCTAssertEqual(package.sha256, digest)
    }

    func testRejectsMismatchedFirmwarePackageDigest() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = makeFirmwareImage(version: "0.7.0")
        let manifest = HardwareFirmwareManifest(
            schemaVersion: 1,
            hardwareModel: HardwareFirmwarePackage.hardwareModel,
            firmwareVersion: "0.7.0",
            monitorProtocolVersion: HardwareMonitorBLEProtocol.protocolVersion,
            updateProtocolVersion: HardwareFirmwareUpdateProtocol.protocolVersion,
            fileName: "tokenrouter_monitor.bin",
            size: image.count,
            sha256: String(repeating: "00", count: 32)
        )
        try image.write(to: directory.appendingPathComponent(manifest.fileName))
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent(HardwareFirmwarePackageLoader.manifestFileName)
        )

        XCTAssertThrowsError(try HardwareFirmwarePackageLoader().load(from: directory)) { error in
            XCTAssertEqual(error as? HardwareFirmwarePackageError, .sha256Mismatch)
        }
    }

    func testArchiveIntegrityValidationAllowsNewerProtocolVersions() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = makeFirmwareImage(version: "0.8.0")
        let digest = Data(SHA256.hash(data: image))
        let manifest = HardwareFirmwareManifest(
            schemaVersion: 1,
            hardwareModel: HardwareFirmwarePackage.hardwareModel,
            firmwareVersion: "0.8.0",
            monitorProtocolVersion: HardwareMonitorBLEProtocol.protocolVersion + 1,
            updateProtocolVersion: HardwareFirmwareUpdateProtocol.protocolVersion + 1,
            fileName: "tokenrouter_monitor.bin",
            size: image.count,
            sha256: digest.hexadecimal
        )
        try image.write(to: directory.appendingPathComponent(manifest.fileName))
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent(HardwareFirmwarePackageLoader.manifestFileName)
        )

        XCTAssertThrowsError(try HardwareFirmwarePackageLoader().load(from: directory)) { error in
            XCTAssertEqual(
                error as? HardwareFirmwarePackageError,
                .incompatibleMonitorProtocol(
                    found: HardwareMonitorBLEProtocol.protocolVersion + 1,
                    expected: HardwareMonitorBLEProtocol.protocolVersion
                )
            )
        }
        let package = try HardwareFirmwarePackageLoader().load(
            from: directory,
            requiresCurrentProtocolVersions: false
        )
        XCTAssertEqual(package.version.description, "0.8.0")
        XCTAssertEqual(package.sha256, digest)
    }

    func testRejectsFirmwareWhoseEmbeddedVersionDoesNotMatchManifest() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = makeFirmwareImage(version: "0.6.9")
        let digest = Data(SHA256.hash(data: image))
        let manifest = HardwareFirmwareManifest(
            schemaVersion: 1,
            hardwareModel: HardwareFirmwarePackage.hardwareModel,
            firmwareVersion: "0.7.0",
            monitorProtocolVersion: HardwareMonitorBLEProtocol.protocolVersion,
            updateProtocolVersion: HardwareFirmwareUpdateProtocol.protocolVersion,
            fileName: "tokenrouter_monitor.bin",
            size: image.count,
            sha256: digest.hexadecimal
        )
        try image.write(to: directory.appendingPathComponent(manifest.fileName))
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent(HardwareFirmwarePackageLoader.manifestFileName)
        )

        XCTAssertThrowsError(try HardwareFirmwarePackageLoader().load(from: directory)) { error in
            XCTAssertEqual(
                error as? HardwareFirmwarePackageError,
                .imageVersionMismatch(found: "0.6.9", expected: "0.7.0")
            )
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hardware-firmware-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeFirmwareImage(
        version: String,
        project: String = "tokenrouter_monitor"
    ) -> Data {
        var image = Data(repeating: 0, count: 160)
        image[0] = 0xE9
        image.replaceSubrange(32..<36, with: [0x32, 0x54, 0xCD, 0xAB])
        image.replaceSubrange(48..<(48 + version.utf8.count), with: version.utf8)
        image.replaceSubrange(80..<(80 + project.utf8.count), with: project.utf8)
        return image
    }
}

private extension Data {
    var hexadecimal: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
