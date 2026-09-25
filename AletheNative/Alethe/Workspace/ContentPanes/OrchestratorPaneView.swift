import AletheDesign
import AletheModel
import SwiftUI

/// Orchestrator board pane (upstream `OrchestratorPane`). Until the canvas lands (P6-14) it shows the
/// board's empty state; with the orchestrator feature off it says so and offers to turn it on, since
/// an imported or restored board can outlive the feature.
struct OrchestratorPaneView: View {
    let isFocused: Bool
    let onClose: () -> Void
    let onDrag: (CGSize?) -> Void
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if environment.features.isOn(.orchestrator) {
                    emptyState
                } else {
                    featureOff
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme[.bg])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("orchestrator.pane")
    }

    private var header: some View {
        HStack(spacing: metrics.space(.s)) {
            Image(systemName: "flowchart")
                .font(metrics.font(.caption))
                .foregroundStyle(theme[.textSecondary])
            Text("orchestrator.title")
                .font(metrics.font(.footnote).weight(.medium))
                .foregroundStyle(theme[isFocused ? .textPrimary : .textSecondary])
                .lineLimit(1)
            Spacer(minLength: 0)
            ContentPaneButton(symbol: "xmark", label: "orchestrator.close", id: "pane.close", action: onClose)
        }
        .padding(.horizontal, metrics.space(.m))
        .frame(height: metrics.size(28))
        .background(theme[isFocused ? .bgElevated : .bgSunken])
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { onDrag($0.translation) }
                .onEnded { _ in onDrag(nil) }
        )
        .overlay(alignment: .bottom) { Rectangle().fill(theme[.borderSubtle]).frame(height: 1) }
    }

    private var emptyState: some View {
        VStack(spacing: metrics.space(.s)) {
            Image(systemName: "flowchart")
                .font(metrics.font(.title2))
                .foregroundStyle(theme[.textTertiary])
            Text("orchestrator.empty.title")
                .font(metrics.font(.body).weight(.medium))
                .foregroundStyle(theme[.textPrimary])
            Text("orchestrator.empty.detail")
                .font(metrics.font(.footnote))
                .foregroundStyle(theme[.textSecondary])
        }
        .multilineTextAlignment(.center)
        .padding(metrics.space(.xl))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("orchestrator.empty")
    }

    private var featureOff: some View {
        VStack(spacing: metrics.space(.m)) {
            Text("orchestrator.featureOff")
                .font(metrics.font(.body))
                .foregroundStyle(theme[.textSecondary])
            Button("orchestrator.turnOn") {
                environment.preferences?.update { $0.features.set(.orchestrator, on: true) }
            }
            .accessibilityIdentifier("orchestrator.turnOn")
        }
        .multilineTextAlignment(.center)
        .padding(metrics.space(.xl))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("orchestrator.featureOff")
    }
}
