import SwiftUI

/// The remote sidebar tab Alethe shows in its right sidebar.
struct SampleSidebarView: View {
    @State private var counter: Int?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("sample.name").font(.headline)
            Text("sample.tab.message").foregroundStyle(.secondary)
            Group {
                if let counter {
                    Text(String(format: String(localized: "sample.counter"), counter))
                } else if loaded {
                    Text("sample.storageDenied")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .accessibilityIdentifier("sample.counter")
            HStack {
                Button("sample.increment") {
                    Task { counter = await HostBridge.shared.incrementCounter() }
                }
                .accessibilityIdentifier("sample.increment")
                Button("sample.refresh") {
                    Task { await refresh() }
                }
            }
            #if DEBUG
            // Proves crash isolation: the extension's process dies, Alethe shows "stopped".
            Button("sample.crash", role: .destructive) {
                fatalError("Crash requested from the sample extension")
            }
            .controlSize(.small)
            .accessibilityIdentifier("sample.crash")
            #endif
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("sample.tab")
        .task { await refresh() }
    }

    private func refresh() async {
        counter = await HostBridge.shared.counter()
        loaded = true
    }
}
