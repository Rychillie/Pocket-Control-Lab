import Foundation
import Observation

struct InvestigationLogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let event: String
    let detail: String?

    func text(includeRawExtensionUnitData: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        let renderedDetail: String?
        if includeRawExtensionUnitData == false, event.hasPrefix("XU_") {
            renderedDetail = "Raw Extension Unit data redacted."
        } else if includeRawExtensionUnitData == false, shouldRedactDiagnosticDetail {
            renderedDetail = "Potentially identifying diagnostic detail redacted."
        } else {
            renderedDetail = detail
        }
        let suffix = renderedDetail.map { " \($0)" } ?? ""
        return "[\(formatter.string(from: timestamp))] \(event)\(suffix)"
    }

    var text: String {
        text()
    }

    private var shouldRedactDiagnosticDetail: Bool {
        switch event {
        case "AVCAPTURE_DEVICE_FOUND",
             "PREVIEW_FAILED",
             "SAVE_INVESTIGATION_SUCCESS",
             "SAVE_INVESTIGATION_FAILED":
            true
        default:
            false
        }
    }
}

@MainActor
@Observable
final class InvestigationLogger {
    private(set) var entries: [InvestigationLogEntry] = []

    func log(_ event: String, _ detail: String? = nil) {
        entries.append(InvestigationLogEntry(timestamp: .now, event: event, detail: detail))

        if entries.count > 2_000 {
            entries.removeFirst(entries.count - 2_000)
        }
    }

    func renderedText(includeRawExtensionUnitData: Bool = true) -> String {
        entries.map { $0.text(includeRawExtensionUnitData: includeRawExtensionUnitData) }.joined(separator: "\n")
    }
}
