import Foundation

enum PocketIdentification: Equatable, Sendable {
    /// The USB identity matches the Pocket 4 profile whose UVC control layout
    /// is explicitly whitelisted by the app.
    case confirmedPocket4VIDPID

    /// A DJI Osmo Pocket-family product was observed over USB, but this build
    /// has not validated its UVC entities, selectors, or payload layouts.
    case djiOsmoPocketFamily

    var label: String {
        switch self {
        case .confirmedPocket4VIDPID:
            "Detected live — Pocket 4 USB profile verified"
        case .djiOsmoPocketFamily:
            "Detected live — DJI Osmo Pocket USB device; control profile not verified"
        }
    }

    var supportsPocket4ControlProfile: Bool {
        self == .confirmedPocket4VIDPID
    }
}

struct USBLinkSpeed: Equatable, Sendable {
    let bitsPerSecond: UInt64?
    let rawSpeedCode: UInt64?

    var displayValue: String {
        guard let bitsPerSecond else {
            return rawSpeedCode.map { "Unknown (raw speed \($0))" } ?? "Not published"
        }

        return switch bitsPerSecond {
        case 480_000_000:
            "High-Speed (480 Mb/s)"
        case 5_000_000_000:
            "SuperSpeed (5 Gb/s)"
        case 10_000_000_000:
            "SuperSpeed+ (10 Gb/s)"
        case 12_000_000:
            "Full-Speed (12 Mb/s)"
        case 1_500_000:
            "Low-Speed (1.5 Mb/s)"
        default:
            String(format: "%.3f Gb/s", Double(bitsPerSecond) / 1_000_000_000)
        }
    }
}

struct PocketDevice: Identifiable, Equatable, Sendable {
    let registryID: UInt64
    let vendorID: UInt16?
    let productID: UInt16?
    let manufacturer: String?
    /// Used only to identify the connected USB product. It is intentionally
    /// not displayed or exported because vendors may embed a unique suffix.
    let productIdentifier: String?
    let locationID: UInt32?
    let linkSpeed: USBLinkSpeed
    let activeConfiguration: UInt64?
    let enumerationState: UInt64?
    let identification: PocketIdentification

    var id: UInt64 {
        registryID
    }

    var displayName: String {
        switch cameraMatchingToken {
        case "osmopocket4":
            "DJI Osmo Pocket 4"
        case "osmopocket3":
            "DJI Osmo Pocket 3"
        case "osmopocket2":
            "DJI Osmo Pocket 2"
        default:
            "DJI Osmo Pocket"
        }
    }

    var cameraMatchingToken: String {
        let normalizedProduct = normalize(productIdentifier)

        for token in ["osmopocket4", "osmopocket3", "osmopocket2", "osmopocket"] {
            if normalizedProduct.contains(token) {
                return token
            }
        }

        return identification.supportsPocket4ControlProfile ? "osmopocket4" : "osmopocket"
    }

    var formattedVendorID: String {
        vendorID.map { String(format: "%04X", $0) } ?? "—"
    }

    var formattedProductID: String {
        productID.map { String(format: "%04X", $0) } ?? "—"
    }

    var deviceState: String {
        var values: [String] = []

        if let activeConfiguration {
            values.append("Configured (\(activeConfiguration))")
        } else {
            values.append("Configuration not published")
        }

        if let enumerationState {
            values.append("Enumeration state \(enumerationState)")
        }

        return values.joined(separator: " · ")
    }

    var supportsPocket4ControlProfile: Bool {
        identification.supportsPocket4ControlProfile
    }

    /// Values that identify a USB connection for lifecycle purposes. Published
    /// properties such as configuration state can change while the same device
    /// is connected and must not restart preview, discovery, or a write batch.
    var connectionIdentity: ConnectionIdentity {
        ConnectionIdentity(
            registryID: registryID,
            locationID: locationID,
            identification: identification
        )
    }

    private func normalize(_ value: String?) -> String {
        guard let value else {
            return ""
        }
        return value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
    }
}

struct ConnectionIdentity: Equatable, Sendable {
    let registryID: UInt64
    let locationID: UInt32?
    let identification: PocketIdentification
}

struct CameraDeviceInfo: Identifiable, Equatable, Sendable {
    let localizedName: String
    let uniqueID: String
    let modelID: String
    let manufacturer: String
    let deviceType: String
    let transportType: String
    let activeFormat: VideoFormatInfo
    let activeMinimumFrameDuration: String
    let activeMaximumFrameDuration: String
    let formats: [VideoFormatInfo]

    var id: String {
        uniqueID
    }
}

struct VideoFormatInfo: Identifiable, Equatable, Sendable {
    let id: String
    let mediaType: String
    let mediaSubType: String
    let width: Int32
    let height: Int32
    let frameRateDescription: String

    var displayName: String {
        "\(width)×\(height) · \(mediaSubType) · \(frameRateDescription)"
    }
}

struct CMIOControlObservation: Identifiable, Equatable, Sendable {
    let id: UInt32
    let controlName: String
    let className: String
    let isSettable: Bool?
    let nativeValue: [UInt8]?
    let nativeRange: [UInt8]?
    let absoluteValue: Float?
    let absoluteRange: [UInt8]?

    var hasAnyLiveValue: Bool {
        nativeValue != nil || nativeRange != nil || absoluteValue != nil || absoluteRange != nil
    }
}
