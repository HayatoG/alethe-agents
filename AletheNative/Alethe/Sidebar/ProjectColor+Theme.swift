import AletheDesign
import AletheModel
import SwiftUI

extension ProjectColor {
    var token: ThemeToken {
        switch self {
        case .orange: .projectOrange
        case .pink: .projectPink
        case .purple: .projectPurple
        case .blue: .projectBlue
        case .teal: .projectTeal
        case .green: .projectGreen
        case .yellow: .projectYellow
        case .red: .projectRed
        case .gray: .projectGray
        case .black: .projectBlack
        }
    }

    /// Rotates through the palette so consecutive new projects differ.
    static func next(after count: Int) -> ProjectColor {
        allCases[count % allCases.count]
    }
}
