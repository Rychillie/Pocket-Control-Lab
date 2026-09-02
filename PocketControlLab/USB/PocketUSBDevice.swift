import Foundation
import IOKit
import IOKit.usb

enum PocketUSBDeviceScanner {
    private static let expectedVendorID: UInt16 = 0x2CA3
    private static let expectedProductID: UInt16 = 0x0023

    static func currentPocketDevice() -> PocketDevice? {
        guard let matchingDictionary = IOServiceMatching("IOUSBHostDevice") else {
            return nil
        }

        var iterator: io_iterator_t = IO_OBJECT_NULL
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator)
        guard status == KERN_SUCCESS else {
            return nil
        }
        defer {
            IOObjectRelease(iterator)
        }

        var confirmedPocket4: PocketDevice?
        var pocketFamilyDevice: PocketDevice?

        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else {
                break
            }
            defer {
                IOObjectRelease(service)
            }

            if let device = device(from: service) {
                switch device.identification {
                case .confirmedPocket4VIDPID:
                    confirmedPocket4 = preferredDevice(confirmedPocket4, device)
                case .djiOsmoPocketFamily:
                    pocketFamilyDevice = preferredDevice(pocketFamilyDevice, device)
                }
            }

        }

        // A verified Pocket 4 profile always wins over a family-only match.
        // This keeps the current single-device UI deterministic when more than
        // one DJI camera is attached.
        return confirmedPocket4 ?? pocketFamilyDevice
    }

    private static func device(from service: io_service_t) -> PocketDevice? {
        let vendorID = number(service, key: "idVendor").flatMap { UInt16(exactly: $0) }
        let productID = number(service, key: "idProduct").flatMap { UInt16(exactly: $0) }
        let manufacturer = string(service, key: "USB Vendor Name") ?? string(service, key: "kUSBVendorString")
        let product = string(service, key: "USB Product Name") ?? string(service, key: "kUSBProductString")

        let normalizedProduct = normalize(product)
        let isDJI = vendorID == expectedVendorID
            || manufacturer?.localizedCaseInsensitiveContains("DJI") == true
        let isPocketFamily = isDJI && normalizedProduct.contains("osmopocket")
        // VID/PID is necessary but not sufficient: a live Pocket 4 profile
        // also requires the published DJI Osmo Pocket 4 product identity.
        // Failing closed here prevents a different device that reuses the pair
        // from reaching the UVC control bridge.
        let isConfirmedPocket4 = vendorID == expectedVendorID
            && productID == expectedProductID
            && isDJI
            && normalizedProduct.contains("osmopocket4")

        guard isConfirmedPocket4 || isPocketFamily else {
            return nil
        }

        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else {
            return nil
        }

        return PocketDevice(
            registryID: registryID,
            vendorID: vendorID,
            productID: productID,
            manufacturer: manufacturer,
            productIdentifier: product,
            locationID: number(service, key: "locationID").flatMap { UInt32(exactly: $0) },
            linkSpeed: USBLinkSpeed(
                bitsPerSecond: number(service, key: "UsbLinkSpeed"),
                rawSpeedCode: number(service, key: "USBSpeed") ?? number(service, key: "Device Speed")
            ),
            activeConfiguration: number(service, key: "kUSBCurrentConfiguration"),
            enumerationState: number(service, key: "UsbEnumerationState"),
            identification: isConfirmedPocket4 ? .confirmedPocket4VIDPID : .djiOsmoPocketFamily
        )
    }

    private static func preferredDevice(_ current: PocketDevice?, _ candidate: PocketDevice) -> PocketDevice {
        guard let current else {
            return candidate
        }

        let currentLocation = current.locationID ?? .max
        let candidateLocation = candidate.locationID ?? .max
        if candidateLocation != currentLocation {
            return candidateLocation < currentLocation ? candidate : current
        }

        return candidate.registryID < current.registryID ? candidate : current
    }

    private static func normalize(_ value: String?) -> String {
        guard let value else {
            return ""
        }
        return value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
    }

    private static func string(_ service: io_service_t, key: String) -> String? {
        guard let unmanagedValue = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return nil
        }

        let value = unmanagedValue.takeRetainedValue()
        guard CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }

        return value as? String
    }

    private static func number(_ service: io_service_t, key: String) -> UInt64? {
        guard let unmanagedValue = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return nil
        }

        let value = unmanagedValue.takeRetainedValue()
        guard CFGetTypeID(value) == CFNumberGetTypeID() else {
            return nil
        }

        var number: Int64 = 0
        guard CFNumberGetValue((value as! CFNumber), .sInt64Type, &number), number >= 0 else {
            return nil
        }
        return UInt64(number)
    }
}

@MainActor
final class PocketUSBRegistryMonitor {
    private var timer: Timer?
    private var lastDevice: PocketDevice?
    private var lastConnectionIdentity: ConnectionIdentity?
    private let interval: TimeInterval
    private let onChange: (PocketDevice?) -> Void

    init(interval: TimeInterval = 1.5, onChange: @escaping (PocketDevice?) -> Void) {
        self.interval = interval
        self.onChange = onChange
    }

    func start() {
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        timer?.tolerance = 0.25
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let currentDevice = PocketUSBDeviceScanner.currentPocketDevice()
        let currentConnectionIdentity = currentDevice?.connectionIdentity
        guard currentConnectionIdentity != lastConnectionIdentity else {
            // Keep the most recent read-only metadata for a stable connection,
            // but do not restart preview or UVC discovery when a transient
            // IORegistry property changes.
            lastDevice = currentDevice
            return
        }

        lastDevice = currentDevice
        lastConnectionIdentity = currentConnectionIdentity
        onChange(currentDevice)
    }
}
