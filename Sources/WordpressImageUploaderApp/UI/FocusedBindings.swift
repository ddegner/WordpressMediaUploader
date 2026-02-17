import SwiftUI

struct WindowCommandActions {
    let createProfile: () -> Void
    let editSelectedProfile: () -> Void
    let deleteSelectedProfile: () -> Void
    let addFiles: () -> Void
    let deleteSelectedFiles: () -> Void
    let resetQueueAndCurrentJob: () -> Void
    let retryFailedFiles: () -> Void
    let stopUpload: () -> Void
    let startUpload: () -> Void
    let clearJobHistory: () -> Void
    let openLog: () -> Void
    let copyVisibleLog: () -> Void
    let copyReport: () -> Void
    let exportJSONReport: () -> Void
    let exportCSVReport: () -> Void
    let showActiveJobTab: () -> Void
    let showTerminalTab: () -> Void
    let showJobHistoryTab: () -> Void

    let canEditSelectedProfile: Bool
    let canDeleteSelectedProfile: Bool
    let canDeleteSelectedFiles: Bool
    let canResetQueueAndCurrentJob: Bool
    let canRetryFailedFiles: Bool
    let canStopUpload: Bool
    let canStartUpload: Bool
    let canClearJobHistory: Bool
    let canOpenLog: Bool
    let canCopyVisibleLog: Bool
    let canCopyReport: Bool
    let canExportJSONReport: Bool
    let canExportCSVReport: Bool
}

private struct ShowProfilesDrawerBindingKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct ShowOperationsDrawerBindingKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct WindowCommandActionsKey: FocusedValueKey {
    typealias Value = WindowCommandActions
}

extension FocusedValues {
    var showProfilesDrawerBinding: Binding<Bool>? {
        get { self[ShowProfilesDrawerBindingKey.self] }
        set { self[ShowProfilesDrawerBindingKey.self] = newValue }
    }

    var showOperationsDrawerBinding: Binding<Bool>? {
        get { self[ShowOperationsDrawerBindingKey.self] }
        set { self[ShowOperationsDrawerBindingKey.self] = newValue }
    }

    var windowCommandActions: WindowCommandActions? {
        get { self[WindowCommandActionsKey.self] }
        set { self[WindowCommandActionsKey.self] = newValue }
    }
}
