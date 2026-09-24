import AletheModel

/// A sheet the main window should present.
enum EditorRequest: Identifiable, Hashable {
    case newProject(ProjectLocation)
    case editProject(ProjectID)
    case newGroup(parent: GroupID?)
    case editGroup(GroupID)
    /// New terminal in a project (nil: the selected one).
    case newTerminal(ProjectID?)
    /// Import from the Tauri app's data.
    case importTauri

    var id: String {
        switch self {
        case .newProject: "newProject"
        case .editProject(let id): "editProject:\(id)"
        case .newGroup: "newGroup"
        case .editGroup(let id): "editGroup:\(id)"
        case .newTerminal: "newTerminal"
        case .importTauri: "importTauri"
        }
    }
}
