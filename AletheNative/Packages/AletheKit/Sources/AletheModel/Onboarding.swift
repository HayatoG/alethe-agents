import Foundation

/// Steps of the first-run sheet (upstream `OnboardingModal`, SET-7).
public enum OnboardingStep: String, CaseIterable, Codable, Sendable {
    case name
    /// The Tauri app's data, offered only when it exists. Right after the name so the imported theme,
    /// agents and features show in the steps that follow.
    case importData
    case appearance
    case agents
    case features
    /// MCP servers found per agent (upstream `McpStep`); only while the MCP feature is on.
    case mcp

    /// The steps shown, in order.
    public static func steps(tauriDataAvailable: Bool, mcpEnabled: Bool) -> [OnboardingStep] {
        allCases.filter { step in
            switch step {
            case .importData: tauriDataAvailable
            case .mcp: mcpEnabled
            case .name, .appearance, .agents, .features: true
            }
        }
    }
}

/// What the launch greets the user with.
public enum LaunchGreeting: Equatable, Sendable {
    case none
    case onboarding
    case welcomeBack(WelcomeBack)
}

/// The welcome-back sheet (upstream `WelcomeModal`), after an update or a long absence.
public struct WelcomeBack: Hashable, Sendable {
    /// Days since the first launch, counting that day as 1 (upstream `daysSince`).
    public var day: Int
    /// The version run before, when this launch runs a different one.
    public var updatedFrom: String?
    /// Whole days since the previous launch, when that is at least `WelcomeBack.absence`.
    public var absentDays: Int?

    public init(day: Int, updatedFrom: String? = nil, absentDays: Int? = nil) {
        self.day = day
        self.updatedFrom = updatedFrom
        self.absentDays = absentDays
    }

    /// A launch this long after the previous one counts as a long absence.
    public static let absence: TimeInterval = 7 * 86_400

    public static func day(since first: Date?, now: Date) -> Int {
        guard let first else { return 1 }
        return max(1, Int((now.timeIntervalSince(first) / 86_400).rounded(.down)) + 1)
    }
}

extension PreferencesDocument {
    /// Records this launch and decides the greeting. The onboarding runs until it is finished or
    /// skipped (`onboardingDone`); a profile that already has projects predates the onboarding and is
    /// marked done without it. Welcome back needs a previous launch recorded by this version of the
    /// app, so an install upgrading into this feature is not greeted.
    public mutating func recordLaunch(version: String, hasProjects: Bool, now: Date = Date()) -> LaunchGreeting {
        defer {
            if firstLaunchAt == nil { firstLaunchAt = now }
            lastLaunchAt = now
            lastSeenVersion = version
        }
        guard onboardingDone == true else {
            if hasProjects {
                onboardingDone = true
                return .none
            }
            return .onboarding
        }
        let updatedFrom = lastSeenVersion.flatMap { $0 == version ? nil : $0 }
        let absentDays = lastLaunchAt.flatMap { last -> Int? in
            let gap = now.timeIntervalSince(last)
            return gap >= WelcomeBack.absence ? Int((gap / 86_400).rounded(.down)) : nil
        }
        guard updatedFrom != nil || absentDays != nil else { return .none }
        return .welcomeBack(WelcomeBack(day: WelcomeBack.day(since: firstLaunchAt, now: now),
                                        updatedFrom: updatedFrom, absentDays: absentDays))
    }
}

public enum OnboardingName {
    /// The default name: the first word of the macOS account's full name, else the account name.
    public static func suggested(fullName: String, userName: String) -> String {
        let first = fullName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return first.isEmpty ? userName.trimmingCharacters(in: .whitespaces) : first
    }
}
