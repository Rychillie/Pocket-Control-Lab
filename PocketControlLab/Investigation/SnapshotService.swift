import Foundation

enum SnapshotService {
    static func capture(label: String, selectors: [ExtensionUnitSelectorState]) -> ExtensionUnitSnapshot {
        ExtensionUnitSnapshot(label: label, selectors: selectors)
    }

    static func diff(
        source: ExtensionUnitSnapshot,
        destination: ExtensionUnitSnapshot
    ) -> ExtensionUnitDiff {
        let destinationBySelector = Dictionary(uniqueKeysWithValues: destination.selectors.map { ($0.selector, $0) })
        let selectorDiffs = source.selectors.map { sourceSelector -> ExtensionUnitSelectorDiff in
            let before = sourceSelector.currentValue.isSuccess ? sourceSelector.currentValue.bytes : nil
            let destinationSelector = destinationBySelector[sourceSelector.selector]
            let after = destinationSelector?.currentValue.isSuccess == true
                ? destinationSelector?.currentValue.bytes
                : nil

            let changes: [ExtensionUnitByteChange]
            if let before, let after {
                changes = zip(before, after).enumerated().compactMap { index, pair in
                    guard pair.0 != pair.1 else {
                        return nil
                    }
                    return ExtensionUnitByteChange(index: index, before: pair.0, after: pair.1)
                }
            } else {
                changes = []
            }

            return ExtensionUnitSelectorDiff(
                selector: sourceSelector.selector,
                before: before,
                after: after,
                changes: changes
            )
        }

        return ExtensionUnitDiff(
            sourceLabel: source.label,
            destinationLabel: destination.label,
            selectorDiffs: selectorDiffs
        )
    }
}
