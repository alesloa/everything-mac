import SwiftUI

private struct SearchModelFocusKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var searchModel: AppModel? {
        get { self[SearchModelFocusKey.self] }
        set { self[SearchModelFocusKey.self] = newValue }
    }
}

struct FocusedSearchCommands: Commands {
    @FocusedValue(\.searchModel) private var model
    var body: some Commands {
        if let model { AppCommands(model: model) }
    }
}

struct SearchWindowRoot: View {
    let background: AppModel
    let delegate: AppDelegate
    @StateObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase

    init(background: AppModel, delegate: AppDelegate, windowID: String?) {
        self.background = background; self.delegate = delegate
        _model = StateObject(wrappedValue: AppModel(index: background.index,
            preferences: background.preferences,
            workspace: SearchWorkspaceController(library: background.workspace.library, windowID: windowID)))
    }

    var body: some View {
        ContentView().environmentObject(model)
            .frame(minWidth: 800, minHeight: 500)
            .focusedSceneValue(\.searchModel, model)
            .background(GlobalAccessWindowRegistration(model: model).frame(width: 0, height: 0).allowsHitTesting(false))
            .onAppear {
                background.bootstrap()
                model.prepareWindow(with: background)
                model.restoreWorkspace()
                let open = openWindow, settings = openSettings
                delegate.configureGlobalAccess(model: background,
                    openSearchWindow: { open(id: "search", value: UUID().uuidString) },
                    openSettings: { settings() })
                delegate.updateActiveModel(model)
                delegate.restoreSearchWindowsIfNeeded(library: background.workspace.library) {
                    open(id: "search", value: $0)
                }
                Task { await model.runSearch() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { delegate.updateActiveModel(model) }
                if phase == .inactive { model.persistWorkspace() }
            }
    }
}

struct SearchSettingsRoot: View {
    let background: AppModel
    let delegate: AppDelegate
    @State private var activeModel: AppModel?
    var body: some View {
        SettingsView().environmentObject(activeModel ?? background)
            .focusedSceneValue(\.searchModel, activeModel ?? background)
            .onAppear { activeModel = delegate.model ?? background }
    }
}
