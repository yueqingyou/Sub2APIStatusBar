import CryptoKit
import Foundation

public struct HardwareFirmwareVersion: Codable, Comparable, CustomStringConvertible, Sendable {
    public let major: UInt8
    public let minor: UInt8
    public let patch: UInt8

    public init(major: UInt8, minor: UInt8, patch: UInt8) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ value: String) {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = UInt8(components[0]),
              let minor = UInt8(components[1]),
              let patch = UInt8(components[2]) else {
            return nil
        }
        self.init(major: major, minor: minor, patch: patch)
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: HardwareFirmwareVersion, rhs: HardwareFirmwareVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public struct HardwareFirmwareManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let hardwareModel: String
    public let firmwareVersion: String
    public let monitorProtocolVersion: UInt8
    public let updateProtocolVersion: UInt8
    public let fileName: String
    public let size: Int
    public let sha256: String

    public init(
        schemaVersion: Int,
        hardwareModel: String,
        firmwareVersion: String,
        monitorProtocolVersion: UInt8,
        updateProtocolVersion: UInt8,
        fileName: String,
        size: Int,
        sha256: String
    ) {
        self.schemaVersion = schemaVersion
        self.hardwareModel = hardwareModel
        self.firmwareVersion = firmwareVersion
        self.monitorProtocolVersion = monitorProtocolVersion
        self.updateProtocolVersion = updateProtocolVersion
        self.fileName = fileName
        self.size = size
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case hardwareModel = "hardware_model"
        case firmwareVersion = "firmware_version"
        case monitorProtocolVersion = "monitor_protocol_version"
        case updateProtocolVersion = "update_protocol_version"
        case fileName = "file_name"
        case size
        case sha256
    }
}

public struct HardwareFirmwarePackage: Equatable, Sendable {
    public static let hardwareModel = "ESP32-S3-RLCD-4.2"

    public let manifest: HardwareFirmwareManifest
    public let version: HardwareFirmwareVersion
    public let image: Data
    public let sha256: Data

    public init(
        manifest: HardwareFirmwareManifest,
        version: HardwareFirmwareVersion,
        image: Data,
        sha256: Data
    ) {
        self.manifest = manifest
        self.version = version
        self.image = image
        self.sha256 = sha256
    }
}

public enum HardwareFirmwarePackageError: Error, Equatable, LocalizedError, Sendable {
    case missingResourceDirectory
    case invalidManifest
    case unsupportedSchema(Int)
    case unsupportedHardware(String)
    case invalidVersion(String)
    case incompatibleMonitorProtocol(found: UInt8, expected: UInt8)
    case incompatibleUpdateProtocol(found: UInt8, expected: UInt8)
    case unsafeFileName(String)
    case imageReadFailed(String)
    case sizeMismatch(found: Int, expected: Int)
    case invalidSHA256(String)
    case sha256Mismatch
    case invalidESPImage
    case imageProjectMismatch(String)
    case imageVersionMismatch(found: String, expected: String)

    public var errorDescription: String? {
        switch self {
        case .missingResourceDirectory:
            return "The bundled hardware firmware directory is missing."
        case .invalidManifest:
            return "The bundled hardware firmware manifest is invalid."
        case let .unsupportedSchema(schema):
            return "The hardware firmware manifest schema \(schema) is not supported."
        case let .unsupportedHardware(model):
            return "The bundled firmware targets unsupported hardware: \(model)."
        case let .invalidVersion(version):
            return "The bundled hardware firmware version is invalid: \(version)."
        case let .incompatibleMonitorProtocol(found, expected):
            return "The bundled firmware uses monitor protocol \(found), expected \(expected)."
        case let .incompatibleUpdateProtocol(found, expected):
            return "The bundled firmware uses update protocol \(found), expected \(expected)."
        case let .unsafeFileName(fileName):
            return "The hardware firmware file name is unsafe: \(fileName)."
        case let .imageReadFailed(path):
            return "The bundled hardware firmware could not be read: \(path)."
        case let .sizeMismatch(found, expected):
            return "The bundled hardware firmware size is \(found) bytes, expected \(expected)."
        case let .invalidSHA256(value):
            return "The bundled hardware firmware SHA-256 is invalid: \(value)."
        case .sha256Mismatch:
            return "The bundled hardware firmware SHA-256 does not match its manifest."
        case .invalidESPImage:
            return "The bundled hardware firmware is not a valid ESP application image."
        case let .imageProjectMismatch(project):
            return "The bundled hardware firmware has an unexpected project name: \(project)."
        case let .imageVersionMismatch(found, expected):
            return "The bundled hardware firmware version is \(found), expected \(expected)."
        }
    }
}

public struct HardwareFirmwarePackageLoader: Sendable {
    public static let relativeDirectory = "HardwareFirmware/ESP32-S3-RLCD-4.2"
    public static let manifestFileName = "manifest.json"

    public init() {}

    public func loadBundled(bundle: Bundle = .main) throws -> HardwareFirmwarePackage {
        guard let resourceURL = bundle.resourceURL else {
            throw HardwareFirmwarePackageError.missingResourceDirectory
        }
        return try load(
            from: resourceURL.appendingPathComponent(Self.relativeDirectory, isDirectory: true)
        )
    }

    public func load(
        from directoryURL: URL,
        requiresCurrentProtocolVersions: Bool = true
    ) throws -> HardwareFirmwarePackage {
        let manifestURL = directoryURL.appendingPathComponent(Self.manifestFileName)
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        } catch {
            throw HardwareFirmwarePackageError.invalidManifest
        }

        let manifest: HardwareFirmwareManifest
        do {
            manifest = try JSONDecoder().decode(HardwareFirmwareManifest.self, from: manifestData)
        } catch {
            throw HardwareFirmwarePackageError.invalidManifest
        }

        guard manifest.schemaVersion == 1 else {
            throw HardwareFirmwarePackageError.unsupportedSchema(manifest.schemaVersion)
        }
        guard manifest.hardwareModel == HardwareFirmwarePackage.hardwareModel else {
            throw HardwareFirmwarePackageError.unsupportedHardware(manifest.hardwareModel)
        }
        guard let version = HardwareFirmwareVersion(manifest.firmwareVersion) else {
            throw HardwareFirmwarePackageError.invalidVersion(manifest.firmwareVersion)
        }
        if requiresCurrentProtocolVersions {
            guard manifest.monitorProtocolVersion == HardwareMonitorBLEProtocol.protocolVersion else {
                throw HardwareFirmwarePackageError.incompatibleMonitorProtocol(
                    found: manifest.monitorProtocolVersion,
                    expected: HardwareMonitorBLEProtocol.protocolVersion
                )
            }
            guard manifest.updateProtocolVersion == HardwareFirmwareUpdateProtocol.protocolVersion else {
                throw HardwareFirmwarePackageError.incompatibleUpdateProtocol(
                    found: manifest.updateProtocolVersion,
                    expected: HardwareFirmwareUpdateProtocol.protocolVersion
                )
            }
        }
        guard manifest.fileName == (manifest.fileName as NSString).lastPathComponent,
              manifest.fileName != ".",
              manifest.fileName != "..",
              !manifest.fileName.isEmpty else {
            throw HardwareFirmwarePackageError.unsafeFileName(manifest.fileName)
        }

        let imageURL = directoryURL.appendingPathComponent(manifest.fileName)
        let image: Data
        do {
            image = try Data(contentsOf: imageURL, options: [.mappedIfSafe])
        } catch {
            throw HardwareFirmwarePackageError.imageReadFailed(imageURL.path)
        }
        guard image.count == manifest.size else {
            throw HardwareFirmwarePackageError.sizeMismatch(found: image.count, expected: manifest.size)
        }
        guard let expectedSHA256 = Data(hexadecimal: manifest.sha256), expectedSHA256.count == 32 else {
            throw HardwareFirmwarePackageError.invalidSHA256(manifest.sha256)
        }
        let actualSHA256 = Data(SHA256.hash(data: image))
        guard actualSHA256 == expectedSHA256 else {
            throw HardwareFirmwarePackageError.sha256Mismatch
        }
        try validateImageIdentity(image, expectedVersion: manifest.firmwareVersion)

        return HardwareFirmwarePackage(
            manifest: manifest,
            version: version,
            image: image,
            sha256: expectedSHA256
        )
    }

    private func validateImageIdentity(_ image: Data, expectedVersion: String) throws {
        let imageHeaderLength = 24
        let segmentHeaderLength = 8
        let appDescriptionOffset = imageHeaderLength + segmentHeaderLength
        let versionOffset = appDescriptionOffset + 16
        let projectOffset = versionOffset + 32
        let identityEndOffset = projectOffset + 32
        let appDescriptionMagic: [UInt8] = [0x32, 0x54, 0xCD, 0xAB]

        guard image.count >= identityEndOffset,
              image[image.startIndex] == 0xE9,
              Array(image[appDescriptionOffset..<(appDescriptionOffset + 4)]) == appDescriptionMagic,
              let imageVersion = cString(in: image, offset: versionOffset, length: 32),
              let imageProject = cString(in: image, offset: projectOffset, length: 32) else {
            throw HardwareFirmwarePackageError.invalidESPImage
        }
        guard imageProject == "tokenrouter_monitor" else {
            throw HardwareFirmwarePackageError.imageProjectMismatch(imageProject)
        }
        guard imageVersion == expectedVersion else {
            throw HardwareFirmwarePackageError.imageVersionMismatch(
                found: imageVersion,
                expected: expectedVersion
            )
        }
    }

    private func cString(in data: Data, offset: Int, length: Int) -> String? {
        let field = data[offset..<(offset + length)]
        let bytes = field.prefix { $0 != 0 }
        guard !bytes.isEmpty else {
            return nil
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}

public enum HardwareFirmwareUpdateDeviceState: Equatable, Sendable {
    case idle
    case receiving
    case verifying
    case restarting
    case failed
    case unknown(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .idle
        case 1: self = .receiving
        case 2: self = .verifying
        case 3: self = .restarting
        case 4: self = .failed
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .idle: return 0
        case .receiving: return 1
        case .verifying: return 2
        case .restarting: return 3
        case .failed: return 4
        case let .unknown(value): return value
        }
    }
}

public enum HardwareFirmwareUpdateProtocol {
    public static let protocolVersion: UInt8 = 1
    public static let dataCharacteristicUUIDString = "0299C897-440C-4466-BFF3-934103A8601C"
    public static let startPayloadLength = 44
    public static let commandPayloadLength = 5

    private static let magic: [UInt8] = [0x54, 0x52, 0x55]

    private enum Command: UInt8 {
        case start = 0x01
        case finish = 0x02
        case abort = 0x03
    }

    public static func startPayload(for package: HardwareFirmwarePackage) -> Data {
        var bytes = magic + [protocolVersion, Command.start.rawValue]
        appendUInt32(UInt32(clamping: package.image.count), to: &bytes)
        bytes.append(package.version.major)
        bytes.append(package.version.minor)
        bytes.append(package.version.patch)
        bytes.append(contentsOf: package.sha256)
        return Data(bytes)
    }

    public static var finishPayload: Data {
        Data(magic + [protocolVersion, Command.finish.rawValue])
    }

    public static var abortPayload: Data {
        Data(magic + [protocolVersion, Command.abort.rawValue])
    }

    private static func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, through: 24, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }
}

private extension Data {
    init?(hexadecimal: String) {
        let normalized = hexadecimal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count.isMultiple(of: 2),
              normalized.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(normalized.count / 2)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
