import SwiftUI
import Synchronization

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
            let output = await Self.readLog()
            guard !Task.isCancelled else { return }
            text = output
            loading = false
        }
    }

    private nonisolated static func readLog() async -> String {
        let cancelled = Mutex(false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let request = ProcessRequest(executableURL: URL(fileURLWithPath: "/usr/bin/log"),
                        arguments: ["show", "--last", "15m", "--style", "compact", "--info", "--predicate",
                                    #"subsystem == "dev.yieldd" AND category == "agent""#],
                        timeout: 15, outputCapture: .tail(maxBytes: 128 * 1024))
                    let executor = ProcessExecutor(checkCancellation: {
                        if cancelled.withLock({ $0 }) { throw CancellationError() }
                    })
                    do {
                        let output = try executor.execute(request).requireSuccess(for: request).stdoutText
                        let lines = output.trimmingCharacters(in: .newlines).split(separator: "\n", maxSplits: 1)
                        let empty = lines.isEmpty || (lines.count == 1 && lines[0].hasPrefix("Timestamp"))
                        continuation.resume(returning: empty ? "No recent agent messages." : output)
                    } catch {
                        continuation.resume(returning: error.localizedDescription)
                    }
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }
}
