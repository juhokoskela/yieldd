import ServiceManagement
import SwiftUI

struct CompanionSettings: View {
    let model: CompanionModel
    let setBatteryPolicy: @MainActor @Sendable (Bool) -> Void
    @State private var showingError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Toggle("Pause new jobs on battery power", isOn: Binding(
                    get: { model.snapshot?.pauseOnBattery ?? false },
                    set: { enabled in setBatteryPolicy(enabled) }
                ))
                .toggleStyle(.checkbox)
                .disabled(model.snapshot?.pauseOnBattery == nil || model.changing)
                .accessibilityHint("Running jobs finish on both macOS and Linux.")
                Text("Applies to all runners on this Mac. Running jobs finish.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Agent:").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    Text(model.admission)
                }
                if let address = model.snapshot?.server, let host = URL(string: address)?.host {
                    GridRow {
                        Text("Coordinator:").foregroundStyle(.secondary)
                        Text(host).textSelection(.enabled)
                    }
                }
            }
            if let last = model.snapshot?.lastError {
                DisclosureGroup("Last agent error", isExpanded: $showingError) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(last.occurredAt, format: .dateTime.hour().minute().day().month())
                            .foregroundStyle(.secondary)
                        ScrollView { Text(last.message).textSelection(.enabled) }
                            .frame(maxHeight: 88)
                    }
                }
            }
            if let error = model.error {
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                if error == model.rejectedChange {
                    Button("Dismiss") { model.dismissRejection() }
                }
            }
            if model.snapshot == nil && !model.checking {
                HStack {
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    Link("Agent setup guide", destination: URL(string: "https://github.com/juhokoskela/yieldd/blob/main/Docs/connected-mac-prototype.md#connected-agent-at-login")!)
                }
            } else if let snapshot = model.snapshot, snapshot.pauseOnBattery == nil {
                Text("Update the installed agent to use the battery setting.").foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 362)
        .fixedSize(horizontal: false, vertical: true)
    }
}
