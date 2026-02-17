import SwiftUI

enum WorkspaceOperationsTab: String, CaseIterable, Identifiable, Sendable {
    case activeJob
    case terminal
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activeJob: return "Active Job"
        case .terminal: return "Terminal"
        case .history: return "Job History"
        }
    }

    var systemImage: String {
        switch self {
        case .activeJob: return "hourglass"
        case .terminal: return "chevron.left.forwardslash.chevron.right"
        case .history: return "clock"
        }
    }
}

enum WorkspaceLayoutState {
    static let showProfilesDrawerKey = "workspace.showProfilesDrawer"
    static let showOperationsDrawerKey = "workspace.showOperationsDrawer"
    static let operationsTabKey = "workspace.operationsTab"

    static let defaultShowProfilesDrawer = true
    static let defaultShowOperationsDrawer = true
    static let defaultOperationsTab: WorkspaceOperationsTab = .activeJob

    static func restoredOperationsTab(from rawValue: String) -> WorkspaceOperationsTab {
        WorkspaceOperationsTab(rawValue: rawValue) ?? defaultOperationsTab
    }

    static func splitVisibility(forProfilesDrawer isVisible: Bool) -> NavigationSplitViewVisibility {
        isVisible ? .all : .detailOnly
    }

    static func profilesDrawerVisible(for visibility: NavigationSplitViewVisibility) -> Bool {
        switch visibility {
        case .detailOnly:
            return false
        default:
            return true
        }
    }
}

enum WorkspaceCommandState {
    static func canStartUpload(isRunning: Bool, hasSelectedProfile: Bool, queuedCount: Int) -> Bool {
        !isRunning && hasSelectedProfile && queuedCount > 0
    }

    static func canStopUpload(isRunning: Bool) -> Bool {
        isRunning
    }

    static func canClearFiles(isRunning: Bool, queuedCount: Int, hasCurrentJob: Bool) -> Bool {
        !isRunning && (queuedCount > 0 || hasCurrentJob)
    }

    static func canDeleteSelectedFiles(isRunning: Bool, selectedCount: Int, hasQueuedSelection: Bool) -> Bool {
        !isRunning && selectedCount > 0 && hasQueuedSelection
    }

    static func canClearJobHistory(isRunning: Bool, jobCount: Int) -> Bool {
        !isRunning && jobCount > 0
    }
}
