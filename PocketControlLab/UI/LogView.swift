import SwiftUI

struct LogView: View {
    @Bindable var lab: PocketLabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LOG")
                    .font(.headline)

                Spacer()

                Button("Copy Log") {
                    lab.copyLog()
                }

                Button("Save Investigation…") {
                    lab.saveInvestigation()
                }
            }

            Toggle("Include raw Extension Unit data and sensitive diagnostic details in copied/saved logs", isOn: $lab.includeRawExtensionUnitDataInExports)
                .toggleStyle(.checkbox)
                .font(.caption)
                .accessibilityHint("Off by default. Raw Extension Unit payloads and diagnostic details can reveal camera state or local identifiers when shared.")

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(lab.logger.entries) { entry in
                        Text(entry.text)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(entry.id)
                    }
                }
                .padding(8)
            }
            .background(.quaternary, in: .rect(cornerRadius: 6))
            .accessibilityLabel("Detailed investigation log")
        }
        .padding()
    }
}
