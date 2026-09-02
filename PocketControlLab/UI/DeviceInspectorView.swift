import SwiftUI

struct DeviceInspectorView: View {
    let device: PocketDevice?
    let authorization: CameraAuthorization
    let cameraInfo: CameraDeviceInfo?
    let controls: [UVCStandardControlState]
    let extensionUnitSelectors: [ExtensionUnitSelectorState]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("DEVICE") {
                    deviceSection
                }

                GroupBox("AVFOUNDATION") {
                    cameraSection
                }

                GroupBox("UVC STANDARD CONTROLS") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(controls) { control in
                            CapabilityRow(
                                title: control.control.displayName,
                                evidence: control.capability,
                                isEnabled: control.capability.isLive
                            )
                        }
                    }
                }

                GroupBox("DJI EXTENSION UNIT") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Unit 6")
                            Spacer()
                            Text(extensionUnitStatus)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(extensionUnitColor)
                        }
                        Text("GUID 41769EA2-04DE-E347-8B2B-F4341AFF003B")
                            .font(.caption.monospaced())
                        Text(extensionUnitDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(extensionUnitSelectors) { selector in
                            CapabilityRow(
                                title: "Selector \(selector.selector)",
                                evidence: selector.capability,
                                isEnabled: selector.capability.isLive
                            )
                        }
                    }
                }
            }
            .padding()
        }
    }

    private var hasValidatedPocket4Profile: Bool {
        device?.supportsPocket4ControlProfile == true
    }

    private var extensionUnitStatus: String {
        if extensionUnitSelectors.contains(where: { $0.capability.isLive }) {
            return "LIVE YES"
        }
        return hasValidatedPocket4Profile ? "KNOWN" : "UNAVAILABLE"
    }

    private var extensionUnitColor: Color {
        if extensionUnitSelectors.contains(where: { $0.capability.isLive }) {
            return .green
        }
        return hasValidatedPocket4Profile ? .orange : .secondary
    }

    private var extensionUnitDescription: String {
        guard hasValidatedPocket4Profile else {
            return "Only the verified Pocket 4 USB profile has a known Extension Unit layout."
        }
        return "Known from previous descriptor: bNumControls = 2, bmControls = 0x07"
    }

    @ViewBuilder
    private var deviceSection: some View {
        if let device {
            KeyValueRows(rows: [
                ("Model", device.displayName),
                ("Detection", device.identification.label),
                ("VID / PID", "\(device.formattedVendorID) / \(device.formattedProductID)"),
                ("Manufacturer", device.manufacturer ?? "Not published"),
                ("USB speed", device.linkSpeed.displayValue),
                ("State", device.deviceState),
            ])
        } else {
            Text("No DJI Osmo Pocket device is currently visible in the USB registry.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Camera permission: \(authorization.displayName)")
                .foregroundStyle(authorization == .authorized ? Color.primary : Color.orange)

            if let cameraInfo {
                KeyValueRows(rows: [
                    ("localizedName", cameraInfo.localizedName),
                    ("deviceType", cameraInfo.deviceType),
                    ("transportType", cameraInfo.transportType),
                    ("activeFormat", cameraInfo.activeFormat.displayName),
                    ("active min frame", cameraInfo.activeMinimumFrameDuration),
                    ("active max frame", cameraInfo.activeMaximumFrameDuration),
                ])

                DisclosureGroup("Formats exposed by AVFoundation (\(cameraInfo.formats.count))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(cameraInfo.formats) { format in
                            Text(format.displayName)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 4)
                }
            } else {
                Text("No compatible Pocket 4 AVCaptureDevice is visible to this process.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CapabilityRow: View {
    let title: String
    let evidence: CapabilityEvidence
    let isEnabled: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(isEnabled ? .green : .orange)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(evidence.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text(evidence.statusLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isEnabled ? Color.green : Color.orange)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(evidence.label)")
    }
}

struct KeyValueRows: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(row.1)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}
