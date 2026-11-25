import SwiftUI

struct CompanionLog: View {
    @State private var text = ""
    @State private var loading = true
    @State private var refresh = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Last 15 minutes").foregroundStyle(.secondary)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { refresh += 1 }
                    .disabled(loading)
            }
            .padding(12)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text(loading ? "Loading agent log…" : text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 400, minHeight: 180)
        .task(id: refresh) {
            loading = true
            text = await Task.detached(priority: .utility) {
                let request = ProcessRequest(executableURL: URL(fileURLWithPath: "/usr/bin/log"),
                    arguments: ["show", "--last", "15m", "--style", "compact", "--info", "--predicate",
                                #"subsystem == "dev.yieldd" AND category == "agent""#],
                    timeout: 15, outputCapture: .tail(maxBytes: 128 * 1024))
                do {
                    let output = try ProcessExecutor().execute(request).requireSuccess(for: request).stdoutText
                    return output.split(separator: "\n").count < 2 ? "No recent agent messages." : output
                } catch { return error.localizedDescription }
            }.value
            loading = false
        }
    }
}
