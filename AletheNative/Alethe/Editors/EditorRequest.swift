import AletheModel

/// A sheet the main window should present.
enum EditorRequest: Identifiable, Hashable {
    case newProject(ProjectLocation)
    case editProject(ProjectID)
    case newGroup(parent: GroupID?)
    case editGroup(GroupID)

    var id: String {
        switch self {
        case .newProject: "newProject"
        case .editProject(let id): "editProject:\(id)"
        case .newGroup: "newGroup"
        case .editGroup(let id): "editGroup:\(id)"
        }
    }
}
