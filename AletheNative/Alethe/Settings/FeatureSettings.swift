import AletheDesign
import AletheModel
import SwiftUI

/// Settings › Features (upstream `FeaturesPage`): each optional module with its toggle, the secondary
/// ones under “Show more”. A feature's own options appear under it while it is on (`FeatureOptions`).
struct FeatureSettings: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var showsMore = false

    private var secondaryCount: Int { Feature.allCases.filter(\.isSecondary).count }

    var body: some View {
        Form {
            Section {
                ForEach(Feature.allCases.filter { !$0.isSecondary }, id: \.self) { FeatureRow(feature: $0) }
            } footer: {
                Text("settings.features.help")
            }
            Section {
                if showsMore {
                    ForEach(Feature.allCases.filter(\.isSecondary), id: \.self) { FeatureRow(feature: $0) }
                }
                Button {
                    showsMore.toggle()
                } label: {
                    Text(verbatim: showsMore ? String(localized: "settings.features.showFewer")
                         : format("settings.features.showMore", secondaryCount))
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("settings.features.showMore")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(environment.preferences == nil)
        .accessibilityIdentifier("settings.features")
    }
}

private struct FeatureRow: View {
    let feature: Feature
    @Environment(AppEnvironment.self) private var environment

    private var isOn: Binding<Bool> {
        Binding {
            environment.features.isOn(feature)
        } set: { on in
            environment.preferences?.update { $0.features.set(feature, on: on) }
        }
    }

    var body: some View {
        Toggle(isOn: isOn) {
            Text(feature.title)
            Text(feature.detail)
        }
        .accessibilityIdentifier("settings.feature.\(feature.rawValue)")
        if isOn.wrappedValue {
            FeatureOptions(feature: feature)
        }
    }
}

/// The options slot under a feature that is on. Each task that gives a feature options adds its case
/// here (Graphify command P5-17, ai-memory status P5-18, Playwright browser P5-19, GSD Sync model
/// chain P5-24).
private struct FeatureOptions: View {
    let feature: Feature

    var body: some View {
        switch feature {
        case .aiMemory:
            AiMemoryOptions()
        case .browser, .graphify, .mcp, .playwright, .orchestrator, .gsdSync, .prs:
            EmptyView()
        }
    }
}

extension Feature {
    var title: LocalizedStringKey {
        switch self {
        case .browser: "features.browser.title"
        case .graphify: "features.graphify.title"
        case .mcp: "features.mcp.title"
        case .playwright: "features.playwright.title"
        case .orchestrator: "features.orchestrator.title"
        case .gsdSync: "features.gsdSync.title"
        case .aiMemory: "features.aiMemory.title"
        case .prs: "features.prs.title"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .browser: "features.browser.detail"
        case .graphify: "features.graphify.detail"
        case .mcp: "features.mcp.detail"
        case .playwright: "features.playwright.detail"
        case .orchestrator: "features.orchestrator.detail"
        case .gsdSync: "features.gsdSync.detail"
        case .aiMemory: "features.aiMemory.detail"
        case .prs: "features.prs.detail"
        }
    }
}
