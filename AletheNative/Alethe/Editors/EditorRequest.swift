import AletheModel

/// A sheet the main window should present.
enum EditorRequest: Identifiable, Hashable {
    case newProject(ProjectLocation)
    case editProject(ProjectID)
    case newGroup(parent: GroupID?)
    case editGroup(GroupID)
    /// New terminal in a project (nil: the selected one).
    case newTerminal(ProjectID?)
    /// New sub-tab in a pane.
    case newSubTab(PaneID)
    /// Add a file or page pane to a project (nil: the selected one).
    case addContent(ProjectID?)
    /// Quick look at a terminal link (upstream link viewer).
    case previewLink(LinkPreviewTarget)
    /// Import from the Tauri app's data.
    case importTauri
    /// Custom grid designer for a project (upstream `LayoutDesignerModal`).
    case layoutDesigner(ProjectID)
    /// Find/Jump (⌘K; upstream `FindJumpModal`).
    case findJump
    /// Past conversations of a project (nil: the selected one; P3-7).
    case conversations(ProjectID?)
    /// Tokens and cost of a tab's session (P3-8).
    case sessionCost(TabID)
    /// Continue a tab's conversation in the other agent (P3-12).
    case handoff(TabID)
    /// AI usage of the providers (P3-13).
    case aiUsage
    /// Git Control of a project (nil: the selected one; P4-5).
    case gitControl(ProjectID?)

    var id: String {
        switch self {
        case .newProject: "newProject"
        case .editProject(let id): "editProject:\(id)"
        case .newGroup: "newGroup"
        case .editGroup(let id): "editGroup:\(id)"
        case .newTerminal: "newTerminal"
        case .newSubTab(let id): "newSubTab:\(id)"
        case .addContent: "addContent"
        case .previewLink(let target): "previewLink:\(target)"
        case .importTauri: "importTauri"
        case .layoutDesigner(let id): "layoutDesigner:\(id)"
        case .findJump: "findJump"
        case .conversations: "conversations"
        case .sessionCost(let tab): "sessionCost:\(tab)"
        case .handoff(let tab): "handoff:\(tab)"
        case .aiUsage: "aiUsage"
        case .gitControl: "gitControl"
        }
    }
}
