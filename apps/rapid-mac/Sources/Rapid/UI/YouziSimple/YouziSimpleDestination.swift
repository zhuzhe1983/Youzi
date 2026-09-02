import Foundation

/// The stable, task-first primary navigation for Simple Mode.
enum YouziSimpleDestination: String, CaseIterable, Identifiable, Sendable {
    case newTask
    case workspaces
    case helpers
    case knowMe
    case results

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newTask: "新任务"
        case .workspaces: "工作空间"
        case .helpers: "帮手"
        case .knowMe: "知我"
        case .results: "成果"
        }
    }

    var systemImage: String {
        switch self {
        case .newTask: "square.and.pencil"
        case .workspaces: "folder"
        case .helpers: "person.2"
        case .knowMe: "point.3.connected.trianglepath.dotted"
        case .results: "sparkles.rectangle.stack"
        }
    }

    var accessibilityIdentifier: String {
        "YouziSimple.Navigation.\(rawValue)"
    }
}
