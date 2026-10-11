import Foundation
import Combine
import IndexCore

@MainActor
final class SearchWorkspaceController: ObservableObject {
    let library: WorkspaceLibrary
    private let requestedWindowID: String?
    private(set) var windowID: UUID?
    private var initialWindow = SearchWindowState()
    private var subscription: AnyCancellable?
    private var savedSearchSubscription: AnyCancellable?
    private var completionTask: Task<Void, Never>?
    private var recordedStates: [UUID: SearchWorkspaceState] = [:]

    init(library: WorkspaceLibrary = .shared, windowID: String? = nil) {
        self.library = library; self.requestedWindowID = windowID
        subscription = library.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var window: SearchWindowState { windowID.flatMap { library.window($0) } ?? initialWindow }
    var canGoBack: Bool { window.selectedTab.canGoBack }
    var canGoForward: Bool { window.selectedTab.canGoForward }
    var canAddTab: Bool { window.tabs.count < SearchWindowState.maximumTabs }

    func observeSavedSearches(_ onChange: @escaping @MainActor () -> Void) {
        savedSearchSubscription = library.$archive.map(\.savedSearches).removeDuplicates().dropFirst()
            .sink { _ in onChange() }
    }

    @discardableResult func activate(defaultState: SearchWorkspaceState) -> SearchWorkspaceState {
        guard windowID == nil else { return window.selectedTab.state }
        let claimed = library.claimWindow(requestedID: requestedWindowID, defaultState: defaultState)
        for tab in claimed.tabs { recordedStates[tab.id] = tab.state }
        windowID = claimed.id; objectWillChange.send()
        return claimed.selectedTab.state
    }

    func stage(_ state: SearchWorkspaceState) {
        completionTask?.cancel()
        guard windowID != nil else { return }
        var window = window; window.update(state); library.updateWindow(window)
    }

    func recordCompleted(_ state: SearchWorkspaceState) {
        completionTask?.cancel()
        let tabID = window.selectedTabID
        let generation = library.historyGeneration
        guard state.hasSearch, recordedStates[tabID] != state else { return }
        completionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.windowID != nil,
                  self.library.historyGeneration == generation,
                  self.window.selectedTabID == tabID, self.window.selectedTab.state == state else { return }
            guard self.library.archive.historyPolicy.enabled else { return }
            self.recordedStates[tabID] = state
            var window = self.window; window.update(state, record: true)
            self.library.updateWindow(window); self.library.record(state)
        }
    }

    func recordNow(_ state: SearchWorkspaceState) {
        completionTask?.cancel()
        guard windowID != nil else { return }
        recordedStates[window.selectedTabID] = state
        var window = window
        window.update(state, record: library.archive.historyPolicy.enabled)
        library.updateWindow(window); library.record(state)
    }

    func newTab(state: SearchWorkspaceState = SearchWorkspaceState()) -> SearchWorkspaceState? {
        completionTask?.cancel()
        var window = window
        guard window.addTab(state: state) != nil else { return nil }
        recordedStates[window.selectedTabID] = state
        library.updateWindow(window); library.flush(); return window.selectedTab.state
    }

    func closeTab(_ id: UUID) -> SearchWorkspaceState {
        completionTask?.cancel()
        var window = window; window.closeTab(id); library.updateWindow(window); library.flush()
        recordedStates.removeValue(forKey: id)
        return window.selectedTab.state
    }

    func selectTab(_ id: UUID) -> SearchWorkspaceState? {
        completionTask?.cancel()
        var window = window
        guard window.tabs.contains(where: { $0.id == id }) else { return nil }
        window.selectedTabID = id; library.updateWindow(window); library.flush()
        recordedStates[id] = window.selectedTab.state
        return window.selectedTab.state
    }

    func back() -> SearchWorkspaceState? {
        completionTask?.cancel()
        var window = window
        guard let i = window.tabs.firstIndex(where: { $0.id == window.selectedTabID }),
              let state = window.tabs[i].goBack() else { return nil }
        library.updateWindow(window); library.flush(); return state
    }

    func forward() -> SearchWorkspaceState? {
        completionTask?.cancel()
        var window = window
        guard let i = window.tabs.firstIndex(where: { $0.id == window.selectedTabID }),
              let state = window.tabs[i].goForward() else { return nil }
        library.updateWindow(window); library.flush(); return state
    }

    func closeWindow() {
        completionTask?.cancel()
        if let windowID { library.closeWindow(windowID) }
        windowID = nil
    }
}
