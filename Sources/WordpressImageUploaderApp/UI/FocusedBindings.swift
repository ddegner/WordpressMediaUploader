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

extension FocusedValues {
    @Entry var showProfilesDrawerBinding: Binding<Bool>?
    @Entry var showOperationsDrawerBinding: Binding<Bool>?
    @Entry var windowCommandActions: WindowCommandActions?
}
