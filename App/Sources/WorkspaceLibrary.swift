import Foundation
import Combine
import IndexCore

@MainActor
final class WorkspaceLibrary: ObservableObject {
    static let shared = WorkspaceLibrary()
    @Published private(set) var archive: SearchWorkspaceArchive
    @Published private(set) var storageError: String?
    private(set) var historyGeneration: UInt64 = 0
    let preferences: UserDefaults
    private let store: SearchWorkspaceStore?
    private var claimedWindowIDs: Set<UUID> = []
    private var saveTask: Task<Void, Never>?
    private var recoveryRequired = false
    private static let defaultsKey = "workspace.archive.v1"

    init(preferences: UserDefaults = .standard, storageURL: URL? = nil) {
        self.preferences = preferences
        if let storageURL { store = SearchWorkspaceStore(url: storageURL) }
        else if preferences === UserDefaults.standard {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            store = SearchWorkspaceStore(url: support.appendingPathComponent("Everything-Mac/workspaces.json"))
        } else { store = nil }
        do {
            if let store { archive = try store.load() }
            else if let data = preferences.data(forKey: Self.defaultsKey) { archive = try SearchWorkspaceStore.decode(data) }
            else { archive = SearchWorkspaceArchive() }
        } catch {
            archive = SearchWorkspaceArchive()
            recoveryRequired = true
            // Source: the persistence operation's actual Foundation/decoder error.
            storageError = error.localizedDescription
        }
    }

    var savedWindowIDs: [String] { archive.restoreSession ? archive.windows.map { $0.id.uuidString } : [] }
    var unclaimedWindowIDs: [String] {
        archive.restoreSession ? archive.windows.filter { !claimedWindowIDs.contains($0.id) }.map { $0.id.uuidString } : []
    }

    func claimWindow(requestedID: String?, defaultState: SearchWorkspaceState) -> SearchWindowState {
        let requested = requestedID.flatMap(UUID.init(uuidString:))
        if archive.restoreSession, let existing = archive.windows.first(where: {
            !claimedWindowIDs.contains($0.id) && (requested == nil || $0.id == requested)
        }) {
            claimedWindowIDs.insert(existing.id)
            return existing
        }
        var window = SearchWindowState(id: requested ?? UUID(), state: defaultState)
        if archive.windows.contains(where: { $0.id == window.id }) { window = SearchWindowState(state: defaultState) }
        claimedWindowIDs.insert(window.id)
        archive.windows.append(window)
        scheduleSave()
        return window
    }

    func window(_ id: UUID) -> SearchWindowState? { archive.windows.first { $0.id == id } }

    func updateWindow(_ window: SearchWindowState, persist: Bool = true) {
        guard let i = archive.windows.firstIndex(where: { $0.id == window.id }), archive.windows[i] != window else { return }
        archive.windows[i] = window
        if persist { scheduleSave() }
    }

    func closeWindow(_ id: UUID) {
        claimedWindowIDs.remove(id)
        archive.windows.removeAll { $0.id == id }
        flush()
    }

    func saveSearch(_ saved: SavedSearch) throws {
        let name = saved.macroName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            guard SearchMacroExpansion.validName(name) else { throw SearchMacroError.invalidName(name) }
            if archive.savedSearches.contains(where: { $0.id != saved.id && $0.macroName.lowercased() == name.lowercased() }) {
                throw SearchMacroError.duplicate(name)
            }
        }
        var saved = saved; saved.macroName = name
        if let i = archive.savedSearches.firstIndex(where: { $0.id == saved.id }) { archive.savedSearches[i] = saved }
        else { archive.savedSearches.append(saved) }
        flush()
    }

    func deleteSearch(_ id: UUID) {
        archive.savedSearches.removeAll { $0.id == id }
        for wi in archive.windows.indices {
            for ti in archive.windows[wi].tabs.indices {
                if archive.windows[wi].tabs[ti].state.customFilterID == id { archive.windows[wi].tabs[ti].state.customFilterID = nil }
                for ni in archive.windows[wi].tabs[ti].navigation.indices {
                    if archive.windows[wi].tabs[ti].navigation[ni].state.customFilterID == id {
                        archive.windows[wi].tabs[ti].navigation[ni].state.customFilterID = nil
                    }
                }
            }
        }
        for i in archive.savedSearches.indices {
            if archive.savedSearches[i].state.customFilterID == id { archive.savedSearches[i].state.customFilterID = nil }
        }
        flush()
    }

    func record(_ state: SearchWorkspaceState) { archive.record(state); scheduleSave() }
    func clearHistory() { historyGeneration &+= 1; archive.clearHistory(); flush() }
    func deleteHistory(_ id: UUID) { archive.history.removeAll { $0.id == id }; flush() }
    func setHistoryPolicy(_ policy: SearchHistoryPolicy) {
        archive.historyPolicy = policy; archive.pruneHistory()
        if !policy.enabled { historyGeneration &+= 1; archive.clearHistory() }
        flush()
    }
    func setRestoreSession(_ enabled: Bool) { archive.restoreSession = enabled; flush() }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel(); saveTask = nil
        var persisted = archive
        if !persisted.restoreSession { persisted.windows = [] }
        do {
            if recoveryRequired {
                // Preserve unreadable bytes before allowing a fresh workspace to replace them.
                if let store, FileManager.default.fileExists(atPath: store.url.path) {
                    let backup = store.url.appendingPathExtension("unreadable-\(UUID().uuidString)")
                    try FileManager.default.copyItem(at: store.url, to: backup)
                } else if let data = preferences.data(forKey: Self.defaultsKey) {
                    preferences.set(data, forKey: Self.defaultsKey + ".unreadable." + UUID().uuidString)
                }
                recoveryRequired = false
            }
            if let store { try store.save(persisted) }
            else { preferences.set(try SearchWorkspaceStore.encode(persisted), forKey: Self.defaultsKey) }
            storageError = nil
        } catch {
            // Source: the attempted workspace write's actual error, with no invented diagnostic code.
            storageError = error.localizedDescription
        }
    }
}
