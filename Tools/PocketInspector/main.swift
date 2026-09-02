import AVFoundation
import CoreFoundation
import CoreMedia
import CoreMediaIO
import Foundation

// This command is intentionally read-only. It never creates an AVCaptureSession,
// opens a device for configuration, starts streaming, or calls a setter/SET_CUR.

private let includeIdentifiers = CommandLine.arguments.dropFirst().contains("--include-identifiers")

private func identifier(_ value: @autoclosure () -> String) -> String {
    guard includeIdentifiers else {
        return "<redacted; rerun with --include-identifiers>"
    }
    return value()
}

private func u32<T: BinaryInteger>(_ value: T) -> UInt32 {
    UInt32(truncatingIfNeeded: value)
}

private func fourCC(_ value: UInt32) -> String {
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ]

    let printable = bytes.allSatisfy { $0 >= 32 && $0 <= 126 }
    if printable {
        return "'" + String(bytes: bytes, encoding: .ascii)! + "'"
    }
    return String(format: "0x%08X", value)
}

private func bool(_ value: Bool) -> String {
    value ? "YES" : "NO"
}

private func timeDescription(_ time: CMTime) -> String {
    guard time.isValid else { return "invalid" }
    guard time.timescale != 0 else { return "indefinite" }
    return String(format: "%.6f s (%lld/%d)", CMTimeGetSeconds(time), time.value, time.timescale)
}

private func section(_ name: String) {
    print("\n\(name)")
    print(String(repeating: "-", count: name.count))
}

private func devicePositionDescription(_ position: AVCaptureDevice.Position) -> String {
    switch position {
    case .back: return "back"
    case .front: return "front"
    case .unspecified: return "unspecified"
    @unknown default: return "unknown (\(position.rawValue))"
    }
}

private func authorizationDescription(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "not determined"
    @unknown default: return "unknown (\(status.rawValue))"
    }
}

private func formatDescription(_ format: AVCaptureDevice.Format) -> String {
    let description = format.formatDescription
    let mediaType = fourCC(u32(CMFormatDescriptionGetMediaType(description)))
    let mediaSubType = fourCC(u32(CMFormatDescriptionGetMediaSubType(description)))
    let dimensions = CMVideoFormatDescriptionGetDimensions(description)
    let frameRates = format.videoSupportedFrameRateRanges.map { range in
        String(
            format: "%.3f–%.3f fps (durations %@–%@)",
            range.minFrameRate,
            range.maxFrameRate,
            timeDescription(range.minFrameDuration),
            timeDescription(range.maxFrameDuration)
        )
    }

    let formatText = "mediaType=\(mediaType), pixel/codec=\(mediaSubType), " +
        "dimensions=\(dimensions.width)x\(dimensions.height)"
    let ratesText = frameRates.isEmpty ? "none exposed" : frameRates.joined(separator: "; ")
    return "\(formatText), frame rates: \(ratesText)"
}

private func printAVFoundationDevice(_ device: AVCaptureDevice, index: Int) {
    print("\nDevice \(index + 1)")
    print("  Name: \(device.localizedName)")
    print("  Unique ID: \(identifier(device.uniqueID))")
    print("  Model ID: \(device.modelID)")
    print("  Manufacturer: \(device.manufacturer.isEmpty ? "<empty>" : device.manufacturer)")
    print("  Device type: \(device.deviceType.rawValue)")
    print("  Position: \(devicePositionDescription(device.position))")
    print("  Transport type: \(fourCC(u32(device.transportType))) (\(device.transportType))")
    print("  Connected: \(bool(device.isConnected))")
    print("  In use by another app: \(bool(device.isInUseByAnotherApplication))")
    print("  Has video: \(bool(device.hasMediaType(.video)))")
    print("  Has audio: \(bool(device.hasMediaType(.audio)))")
    print("  Has muxed media: \(bool(device.hasMediaType(.muxed)))")

    print("  Active format: \(formatDescription(device.activeFormat))")
    print("  Active min frame duration: \(timeDescription(device.activeVideoMinFrameDuration))")
    print("  Active max frame duration: \(timeDescription(device.activeVideoMaxFrameDuration))")

    print("  Focus controls exposed by AVFoundation:")
    print("    Locked: \(bool(device.isFocusModeSupported(.locked)))")
    print("    Auto focus: \(bool(device.isFocusModeSupported(.autoFocus)))")
    print("    Continuous auto focus: \(bool(device.isFocusModeSupported(.continuousAutoFocus)))")
    print("    Point of interest: \(bool(device.isFocusPointOfInterestSupported))")
    print("    Current mode: \(device.focusMode.rawValue)")
    print("    Adjusting: \(bool(device.isAdjustingFocus))")

    print("  Exposure controls exposed by AVFoundation:")
    print("    Locked: \(bool(device.isExposureModeSupported(.locked)))")
    print("    Auto expose: \(bool(device.isExposureModeSupported(.autoExpose)))")
    print("    Continuous auto exposure: \(bool(device.isExposureModeSupported(.continuousAutoExposure)))")
    print("    Custom exposure: \(bool(device.isExposureModeSupported(.custom)))")
    print("    Point of interest: \(bool(device.isExposurePointOfInterestSupported))")
    print("    Current mode: \(device.exposureMode.rawValue)")
    print("    Adjusting: \(bool(device.isAdjustingExposure))")

    print("  White-balance controls exposed by AVFoundation:")
    print("    Locked: \(bool(device.isWhiteBalanceModeSupported(.locked)))")
    print("    Auto white balance: \(bool(device.isWhiteBalanceModeSupported(.autoWhiteBalance)))")
    print("    Continuous auto white balance: \(bool(device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance)))")
    print("    Current mode: \(device.whiteBalanceMode.rawValue)")
    print("    Adjusting: \(bool(device.isAdjustingWhiteBalance))")

    print("  Formats (\(device.formats.count)):")
    for (formatIndex, format) in device.formats.enumerated() {
        print("    [\(formatIndex)] \(formatDescription(format))")
        let extensions = CMFormatDescriptionGetExtensions(format.formatDescription)
        if let extensions, CFDictionaryGetCount(extensions) > 0 {
            print("        CoreMedia extensions: \(extensions)")
        }
    }

    print("  AVFoundation macOS API note: it does not make ISO, shutter-duration, " +
        "digital-zoom or per-format HDR getters available to macOS clients. Their absence " +
        "here is an API limitation, not proof that the camera lacks those functions.")
}

private func inspectAVFoundation() {
    section("AVFoundation")
    let authorization = AVCaptureDevice.authorizationStatus(for: .video)
    print("Video authorization status (queried only; no access request made): \(authorizationDescription(authorization))")
    let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.external, .builtInWideAngleCamera],
        mediaType: .video,
        position: .unspecified
    )
    let devices = discovery.devices
    print("Video devices discovered: \(devices.count)")

    if devices.isEmpty {
        print("No AVCaptureDevice video device is currently visible to this process.")
        print("This output describes this process's AVFoundation visibility only; it does not " +
            "establish whether a physical UVC device is enumerated elsewhere in macOS.")
        return
    }

    for (index, device) in devices.enumerated() {
        printAVFoundationDevice(device, index: index)
    }
}

private func cmioAddress(
    _ selector: UInt32,
    scope: UInt32 = u32(kCMIOObjectPropertyScopeGlobal),
    element: UInt32 = u32(kCMIOObjectPropertyElementMain)
) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

private enum CMIOReadResult {
    case absent
    case failure(OSStatus)
    case data(Data)
}

private func cmioHasProperty(
    _ objectID: CMIOObjectID,
    selector: UInt32,
    scope: UInt32 = u32(kCMIOObjectPropertyScopeGlobal)
) -> Bool {
    var address = cmioAddress(selector, scope: scope)
    return CMIOObjectHasProperty(objectID, &address)
}

private func cmioPropertyIsSettable(
    _ objectID: CMIOObjectID,
    selector: UInt32,
    scope: UInt32 = u32(kCMIOObjectPropertyScopeGlobal)
) -> Bool? {
    guard cmioHasProperty(objectID, selector: selector, scope: scope) else { return nil }
    var address = cmioAddress(selector, scope: scope)
    var isSettable = DarwinBoolean(false)
    let status = CMIOObjectIsPropertySettable(objectID, &address, &isSettable)
    return status == noErr ? isSettable.boolValue : nil
}

private func cmioReadData(
    _ objectID: CMIOObjectID,
    selector: UInt32,
    scope: UInt32 = u32(kCMIOObjectPropertyScopeGlobal)
) -> CMIOReadResult {
    guard cmioHasProperty(objectID, selector: selector, scope: scope) else { return .absent }
    var address = cmioAddress(selector, scope: scope)
    var dataSize: UInt32 = 0
    let sizeStatus = CMIOObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize)
    guard sizeStatus == noErr else { return .failure(sizeStatus) }
    guard dataSize > 0 else { return .data(Data()) }

    var data = Data(repeating: 0, count: Int(dataSize))
    var used: UInt32 = 0
    let readStatus = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> OSStatus in
        CMIOObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            dataSize,
            &used,
            buffer.baseAddress
        )
    }
    guard readStatus == noErr else { return .failure(readStatus) }
    return .data(Data(data.prefix(Int(used))))
}

private func cmioUInt32(
    _ objectID: CMIOObjectID,
    selector: UInt32,
    scope: UInt32 = u32(kCMIOObjectPropertyScopeGlobal)
) -> UInt32? {
    guard case let .data(data) = cmioReadData(objectID, selector: selector, scope: scope),
          data.count == MemoryLayout<UInt32>.size
    else { return nil }
    return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
}

private func cmioFloat32(
    _ objectID: CMIOObjectID,
    selector: UInt32,
    scope: UInt32 = u32(kCMIOObjectPropertyScopeGlobal)
) -> Float? {
    guard case let .data(data) = cmioReadData(objectID, selector: selector, scope: scope),
          data.count == MemoryLayout<Float>.size
    else { return nil }
    return data.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
}

private func cmioObjectIDs(
    _ objectID: CMIOObjectID,
    selector: UInt32,
    scope: UInt32 = u32(kCMIOObjectPropertyScopeGlobal)
) -> [CMIOObjectID] {
    guard case let .data(data) = cmioReadData(objectID, selector: selector, scope: scope),
          data.count.isMultiple(of: MemoryLayout<CMIOObjectID>.size)
    else { return [] }
    return data.withUnsafeBytes { buffer in
        Array(buffer.bindMemory(to: CMIOObjectID.self))
    }
}

private func cmioCFString(
    _ objectID: CMIOObjectID,
    selector: UInt32,
    scope: UInt32 = u32(kCMIOObjectPropertyScopeGlobal)
) -> String? {
    guard case let .data(data) = cmioReadData(objectID, selector: selector, scope: scope),
          data.count == MemoryLayout<UnsafeRawPointer?>.size
    else { return nil }
    return data.withUnsafeBytes { buffer in
        guard let pointer = buffer.loadUnaligned(as: UnsafeRawPointer?.self) else { return nil }
        let cfString = Unmanaged<CFString>.fromOpaque(pointer).takeRetainedValue()
        return cfString as String
    }
}

private func cmioPropertyState(
    _ objectID: CMIOObjectID,
    selector: UInt32,
    scope: UInt32 = u32(kCMIOObjectPropertyScopeGlobal)
) -> String {
    guard cmioHasProperty(objectID, selector: selector, scope: scope) else { return "not present" }
    switch cmioPropertyIsSettable(objectID, selector: selector, scope: scope) {
    case true: return "present; marked settable"
    case false: return "present; read-only"
    case nil: return "present; settable status unavailable"
    }
}

private func controlClassName(_ classID: UInt32) -> String {
    let known: [UInt32: String] = [
        u32(kCMIOControlClassID): "CMIO Control",
        u32(kCMIOBooleanControlClassID): "Boolean Control",
        u32(kCMIOSelectorControlClassID): "Selector Control",
        u32(kCMIOFeatureControlClassID): "Feature Control",
        u32(kCMIOBrightnessControlClassID): "Brightness",
        u32(kCMIOContrastControlClassID): "Contrast",
        u32(kCMIOSaturationControlClassID): "Saturation",
        u32(kCMIOSharpnessControlClassID): "Sharpness",
        u32(kCMIOGainControlClassID): "Gain",
        u32(kCMIOExposureControlClassID): "Exposure",
        u32(kCMIOShutterControlClassID): "Shutter",
        u32(kCMIOIrisControlClassID): "Iris",
        u32(kCMIOFocusControlClassID): "Focus",
        u32(kCMIOZoomControlClassID): "Zoom",
        u32(kCMIOZoomRelativeControlClassID): "Zoom Relative",
        u32(kCMIOPanControlClassID): "Pan",
        u32(kCMIOTiltControlClassID): "Tilt",
        u32(kCMIOPanTiltAbsoluteControlClassID): "Pan/Tilt Absolute",
        u32(kCMIOPanTiltRelativeControlClassID): "Pan/Tilt Relative",
        u32(kCMIORollAbsoluteControlClassID): "Roll Absolute",
        u32(kCMIOWhiteBalanceControlClassID): "White Balance",
        u32(kCMIOWhiteBalanceUControlClassID): "White Balance U",
        u32(kCMIOWhiteBalanceVControlClassID): "White Balance V",
        u32(kCMIOHueControlClassID): "Hue",
        u32(kCMIOGammaControlClassID): "Gamma",
        u32(kCMIOBacklightCompensationControlClassID): "Backlight Compensation",
        u32(kCMIOPowerLineFrequencyControlClassID): "Power Line Frequency",
        u32(kCMIONoiseReductionControlClassID): "Noise Reduction",
    ]
    return known[classID] ?? "Unknown class \(fourCC(classID))"
}

private func printCMIOControl(_ objectID: CMIOObjectID) {
    let classID = cmioUInt32(objectID, selector: u32(kCMIOObjectPropertyClass))
    let name = cmioCFString(objectID, selector: u32(kCMIOObjectPropertyName)) ?? "<unnamed>"
    let classText = classID.map { "\(controlClassName($0)) [\(fourCC($0))]" } ?? "unavailable"
    print("    Control object \(objectID): \(name); class \(classText)")

    let capabilities: [(String, UInt32)] = [
        ("On/off", u32(kCMIOFeatureControlPropertyOnOff)),
        ("Automatic/manual", u32(kCMIOFeatureControlPropertyAutomaticManual)),
        ("Absolute/native", u32(kCMIOFeatureControlPropertyAbsoluteNative)),
        ("Native value", u32(kCMIOFeatureControlPropertyNativeValue)),
        ("Absolute value", u32(kCMIOFeatureControlPropertyAbsoluteValue)),
        ("Native range", u32(kCMIOFeatureControlPropertyNativeRange)),
        ("Absolute range", u32(kCMIOFeatureControlPropertyAbsoluteRange)),
    ]
    for (label, selector) in capabilities where cmioHasProperty(objectID, selector: selector) {
        var detail = cmioPropertyState(objectID, selector: selector)
        if selector == u32(kCMIOFeatureControlPropertyNativeValue),
           let value = cmioFloat32(objectID, selector: selector) {
            detail += String(format: "; current %.6f", value)
        }
        if selector == u32(kCMIOFeatureControlPropertyAbsoluteValue),
           let value = cmioFloat32(objectID, selector: selector) {
            detail += String(format: "; current %.6f", value)
        }
        print("      \(label): \(detail)")
    }
}

private func printCMIODevice(_ objectID: CMIOObjectID, index: Int) {
    let name = cmioCFString(objectID, selector: u32(kCMIOObjectPropertyName)) ?? "<unnamed>"
    let manufacturer = cmioCFString(objectID, selector: u32(kCMIOObjectPropertyManufacturer)) ?? "<unavailable>"
    let uid = identifier(cmioCFString(objectID, selector: u32(kCMIODevicePropertyDeviceUID)) ?? "<unavailable>")
    let modelUID = identifier(cmioCFString(objectID, selector: u32(kCMIODevicePropertyModelUID)) ?? "<unavailable>")
    let transport = cmioUInt32(objectID, selector: u32(kCMIODevicePropertyTransportType))
    let alive = cmioUInt32(objectID, selector: u32(kCMIODevicePropertyDeviceIsAlive))
    let running = cmioUInt32(objectID, selector: u32(kCMIODevicePropertyDeviceIsRunning))

    print("\nCMIO device \(index + 1) (object \(objectID))")
    print("  Name: \(name)")
    print("  Manufacturer: \(manufacturer)")
    print("  Device UID: \(uid)")
    print("  Model UID: \(modelUID)")
    if let transport { print("  Transport: \(fourCC(transport)) (\(transport))") }
    if let alive { print("  Alive: \(alive == 0 ? "NO" : "YES")") }
    if let running { print("  Running: \(running == 0 ? "NO" : "YES")") }

    let streams = cmioObjectIDs(objectID, selector: u32(kCMIODevicePropertyStreams))
    print("  Streams exposed by CoreMediaIO: \(streams.isEmpty ? "none" : streams.map(String.init).joined(separator: ", "))")

    let ownedObjects = cmioObjectIDs(objectID, selector: u32(kCMIOObjectPropertyOwnedObjects))
    let controls = ownedObjects.filter { object in
        guard let classID = cmioUInt32(object, selector: u32(kCMIOObjectPropertyClass)) else { return false }
        return classID == u32(kCMIOControlClassID)
            || classID == u32(kCMIOBooleanControlClassID)
            || classID == u32(kCMIOSelectorControlClassID)
            || classID == u32(kCMIOFeatureControlClassID)
            || controlClassName(classID).hasPrefix("Unknown") == false
    }

    if controls.isEmpty {
        print("  CoreMediaIO control objects: none exposed")
    } else {
        print("  CoreMediaIO control objects (\(controls.count)):")
        controls.forEach(printCMIOControl)
    }
}

private func inspectCoreMediaIO() {
    section("CoreMediaIO")
    let systemObject = u32(kCMIOObjectSystemObject)
    let devices = cmioObjectIDs(systemObject, selector: u32(kCMIOHardwarePropertyDevices))
    print("CMIO devices discovered: \(devices.count)")

    if devices.isEmpty {
        print("No CoreMediaIO device is currently visible to this process.")
        return
    }

    for (index, objectID) in devices.enumerated() {
        printCMIODevice(objectID, index: index)
    }
}

print("PocketInspector — AVFoundation / CoreMediaIO read-only inventory")
print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("Safety: no capture session, configuration lock, setter, USB write, or UVC SET_CUR is used.")
if !includeIdentifiers {
    print("Privacy: camera and CoreMediaIO identifiers are redacted by default.")
}
inspectAVFoundation()
inspectCoreMediaIO()
