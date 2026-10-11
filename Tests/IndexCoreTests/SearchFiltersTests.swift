import Foundation
import Testing
@testable import IndexCore

@Suite struct SearchFiltersTests {
    @Test func allTypeCheckboxesRemainIndependent() {
        var filters = SearchFilters(types: [.files])
        filters.selectType(.images, selected: true)
        #expect(filters.selectedTypes == [.files, .images])
        filters.selectType(.video, selected: true)
        filters.selectType(.folders, selected: true)
        #expect(filters.selectedTypes == [.files, .images, .video, .folders])
        filters.selectType(.files, selected: true)
        #expect(filters.selectedTypes == [.files, .images, .video, .folders])
        filters.selectType(.files, selected: false)
        #expect(filters.selectedTypes == [.images, .video, .folders])
        filters.selectType(.all, selected: true)
        #expect(filters.isEmpty)
        #expect(filters.everythingSelected && filters.selectedTypes == SearchFilters.allTypes)
    }

    @Test func everythingSelectsAndClearsAllWithoutLosingSizesOrLegacyDefaults() throws {
        var filters = SearchFilters(types: [.images, .audio], over: SearchSizeLimit(amount: "500"))
        filters.selectAllTypes(true)
        #expect(filters.everythingSelected && filters.selectedTypes == SearchFilters.allTypes)
        #expect(names(filters) == ["report-large.jpg", "report-video.mp4", "report-upper.zip", "other.jpg"])
        filters.selectAllTypes(false)
        #expect(filters.selectedTypes.isEmpty && !filters.everythingSelected && !filters.isEmpty)
        #expect(names(filters).isEmpty)
        #expect(filters.over?.amount == "500")
        let roundTrip = try JSONDecoder().decode(SearchFilters.self, from: JSONEncoder().encode(filters))
        #expect(roundTrip == filters && names(roundTrip).isEmpty)
        let legacy = try JSONDecoder().decode(SearchFilters.self, from: Data("{\"types\":[]}".utf8))
        #expect(legacy.isEmpty && legacy.everythingSelected)
        #expect(names(legacy).count == fixture().count)
        filters.selectType(.images, selected: true)
        filters.selectType(.files, selected: true)
        #expect(filters.selectedTypes == [.images, .files])
        #expect(names(filters) == ["report-large.jpg", "report-video.mp4", "report-upper.zip", "other.jpg"])
    }
    private func fixture() -> FileStore {
        var store = FileStore()
        for (name, bytes, directory) in [
            ("report-small.pdf", UInt64(499_999_999), false),
            ("report-edge.pdf", UInt64(500_000_000), false),
            ("report-large.jpg", UInt64(500_000_001), false),
            ("report-video.mp4", UInt64(1_999_999_999), false),
            ("report-upper.zip", UInt64(2_000_000_000), false),
            ("other.jpg", UInt64(800_000_000), false),
            ("folder.jpg", UInt64(800_000_000), true)
        ] {
            store.append(name: name, parent: FileStore.noParent, size: bytes, mtime: 0, isDir: directory, volID: 1)
        }
        return store
    }
    private func names(_ filters: SearchFilters, text: String = "", regex: Bool = false) -> Set<String> {
        let store = fixture()
        return Set(QueryEngine().search(filters.applying(to: Query(text: text, regex: regex)), in: store).map { store.name(of: $0) })
    }

    @Test func multipleTypesFormAUnionThenNarrowTheEnteredQuery() {
        let filters = SearchFilters(types: [.images, .video])
        #expect(names(filters, text: "report") == ["report-large.jpg", "report-video.mp4"])
        #expect(names(filters, text: "^report-", regex: true) == ["report-large.jpg", "report-video.mp4"])
        #expect(names(SearchFilters(types: [.files, .folders])) == Set((0..<fixture().count).map { fixture().name(of: UInt32($0)) }))
        #expect(!names(SearchFilters(types: [.images])).contains("folder.jpg"))
    }

    @Test func overAndUnderUseStrictDecimalByteBounds() {
        let over = SearchFilters(over: SearchSizeLimit(amount: "500", unit: .megabytes))
        #expect(names(over) == ["report-large.jpg", "report-video.mp4", "report-upper.zip", "other.jpg"])
        let under = SearchFilters(under: SearchSizeLimit(amount: "0.5", unit: .gigabytes))
        #expect(names(under) == ["report-small.pdf"])
        let range = SearchFilters(types: [.images, .video, .archives], over: over.over,
            under: SearchSizeLimit(amount: "2", unit: .gigabytes))
        #expect(names(range, text: "report") == ["report-large.jpg", "report-video.mp4"])
        #expect(range.validationError == nil)
        #expect((try? SearchSizeLimit(amount: " 0.5 ", unit: .gigabytes).byteCount()) == 500_000_000)
    }

    @Test func invalidSizesCannotBecomeQueryOperatorsOrImpossibleRanges() {
        for amount in ["", "-1", "NaN", "1MB", "1..2", "1 | folder:", "1,5", "0.00000001", "18446744073709551616"] {
            #expect(SearchFilters(over: SearchSizeLimit(amount: amount, unit: .bytes)).validationError != nil)
        }
        for upper in ["499", "500"] {
            #expect(SearchFilters(over: SearchSizeLimit(amount: "500"), under: SearchSizeLimit(amount: upper)).validationError != nil)
        }
        #expect(SearchFilters(over: SearchSizeLimit(amount: "500"), under: SearchSizeLimit(amount: "1", unit: .gigabytes)).validationError == nil)
        #expect(SearchSizeLimit(amount: String(UInt64.max), unit: .bytes).queryValue == "18446744073709551615B")
    }

    @Test func filtersPersistThroughTabsBookmarksHistoryAndOldArchives() throws {
        var state = SearchWorkspaceState(query: "report")
        state.filters = SearchFilters(types: [.images, .video], over: SearchSizeLimit(amount: "500"),
            under: SearchSizeLimit(amount: "2", unit: .gigabytes))
        var archive = SearchWorkspaceArchive()
        archive.windows = [SearchWindowState(state: state)]
        archive.savedSearches = [SavedSearch(name: "Large media", state: state, macroName: "large", isCustomFilter: true)]
        archive.record(state)
        #expect(try SearchWorkspaceStore.decode(SearchWorkspaceStore.encode(archive)) == archive)
        var old = SearchWorkspaceState(); old.searchFilter = .files
        let encoded = try JSONEncoder().encode(old)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("\"filters\""))
        let decoded = try JSONDecoder().decode(SearchWorkspaceState.self, from: encoded)
        #expect(decoded.effectiveFilters.types == [.files])
        #expect(decoded.effectiveFilters.over == nil && decoded.effectiveFilters.under == nil)
        #expect(state.hasSearch)
    }

    @Test func savedMacrosAndCustomFiltersRetainAllSizeAndTypeRestrictions() throws {
        var savedState = SearchWorkspaceState()
        savedState.filters = SearchFilters(types: [.images, .video], over: SearchSizeLimit(amount: "500"),
            under: SearchSizeLimit(amount: "2", unit: .gigabytes))
        let saved = SavedSearch(name: "Large media", state: savedState, macroName: "large", isCustomFilter: true)
        let expansion = SearchMacroExpansion(savedSearches: [saved])
        var state = SearchWorkspaceState(query: "report"); state.customFilterID = saved.id
        let store = fixture()
        for query in [try expansion.resolve(state), Query(text: try expansion.expand("macro:large report"))] {
            #expect(query.validationError == nil)
            #expect(Set(QueryEngine().search(query, in: store).map { store.name(of: $0) }) == ["report-large.jpg", "report-video.mp4"])
        }
        state.filters = SearchFilters(over: SearchSizeLimit(amount: "1 | folder:"))
        #expect(throws: QueryValidationError.self) { try expansion.resolve(state) }
    }
}
