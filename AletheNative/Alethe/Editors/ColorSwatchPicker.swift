import AletheDesign
import AletheModel
import SwiftUI

/// Project/group color choice as theme swatches (never literal colors).
struct ColorSwatchPicker: View {
    @Binding var selection: ProjectColor?
    var allowsNone = false
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.space(.s)) {
            if allowsNone {
                swatch(nil)
            }
            ForEach(ProjectColor.allCases, id: \.self) { color in
                swatch(color)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.color")
    }

    private func swatch(_ color: ProjectColor?) -> some View {
        let isSelected = selection == color
        return Button {
            selection = color
        } label: {
            ZStack {
                Circle()
                    .fill(color.map { theme[$0.token] } ?? theme[.panel])
                if color == nil {
                    Image(systemName: "slash.circle").foregroundStyle(theme[.textTertiary])
                }
            }
            .frame(width: metrics.size(18), height: metrics.size(18))
            .overlay(Circle().strokeBorder(theme[.focusRing], lineWidth: isSelected ? 2 : 0))
            .padding(2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(color?.localizedName ?? "color.none"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("editor.color.\(color?.rawValue ?? "none")")
    }
}
