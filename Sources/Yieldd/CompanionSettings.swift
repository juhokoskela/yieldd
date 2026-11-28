import ServiceManagement
import SwiftUI

struct CompanionSettings: View {
    let model: CompanionModel
    let setBatteryPolicy: @MainActor @Sendable (Bool) -> Void
    let setMeetingCPUs: @MainActor @Sendable (Int) -> Void
    @State private var showingError = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

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
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Meeting mode CPU limit:")
                    Spacer()
                    Picker("Meeting mode CPU limit", selection: Binding(
                        get: { model.snapshot?.meetingModeCPUs ?? HostHardwareProfile.current.defaultMeetingModeCPUs },
                        set: { cpus in setMeetingCPUs(cpus) }
                    )) {
                        Text("2 vCPUs").tag(2)
                        Text("4 vCPUs").tag(4)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .disabled(model.snapshot == nil || model.changing)
                }
                Text("Caps Meeting Mode to 1 Linux runner on AC power. macOS jobs use hosted overflow.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Toggle("Open menu bar companion at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            loginItemError = nil
                        } catch {
                            loginItemError = describeError(error)
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                ))
                .toggleStyle(.checkbox)
                Text("Shows the yieldd icon automatically at login. Separate from the background runner agent.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
                }
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
                if let memory = model.snapshot?.memory {
                    let reservedGiB = Double(memory.reservedBytes) / 1_073_741_824
                    let budgetGiB = Double(memory.budgetBytes) / 1_073_741_824
                    GridRow {
                        Text("Memory:").foregroundStyle(.secondary)
                        Text(String(format: "%.1f / %.1f GiB reserved (%@)", reservedGiB, budgetGiB, memory.pressure.rawValue))
                    }
                }
                if let power = model.snapshot?.hostPower {
                    GridRow {
                        Text("Power:").foregroundStyle(.secondary)
                        Text(powerDescription(power, thermal: model.snapshot?.thermalState))
                    }
                }
                if model.snapshot == nil, let report = model.unavailableReport {
                    GridRow {
                        Text("Login Item:").foregroundStyle(.secondary)
                        Text(report.registration.rawValue)
                    }
                }
            }
            if let last = model.snapshot?.lastError ?? model.unavailableReport?.lastFailure {
                DisclosureGroup(model.snapshot == nil ? "Last startup failure" : "Last agent error", isExpanded: $showingError) {
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
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func powerDescription(_ power: HostPowerStatus, thermal: HostThermalState?) -> String {
        var parts = [power.source == .ac ? "AC power" : (power.source == .battery ? "Battery" : "Unknown")]
        if let percent = power.batteryPercent { parts[0] += " (\(percent)%)" }
        if power.drainingOnAC { parts.append("draining") }
        if power.lowPowerMode { parts.append("Low Power Mode") }
        if let thermal { parts.append("thermal \(thermal.rawValue)") }
        return parts.joined(separator: " · ")
    }
}
