import SwiftUI

private struct ShowProfilesDrawerBindingKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct ShowOperationsDrawerBindingKey: FocusedValueKey {
    typealias Value = Binding<Bool>
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
}
