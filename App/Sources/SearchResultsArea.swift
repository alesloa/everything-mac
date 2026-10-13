import SwiftUI
import IndexCore

struct SearchResultsArea: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var folders: FolderDetailsModel
    @StateObject private var treeState = FolderSidebarState()

    init(model: AppModel) {
        self.model = model
        _folders = ObservedObject(wrappedValue: model.folderDetails)
    }

    private var totals: FolderSnapshot? {
        guard model.indexedFolderTotals, folders.snapshot?.snapshotID == model.resultSnapshotID else { return nil }
        return folders.snapshot
    }

    var body: some View {
        HSplitView {
            if model.folderSidebarVisible {
                FolderSidebarView(snapshot: folders.snapshot, selectedScope: model.folderSearchScope,
                                  onSelect: { model.setFolderSearchScope($0) }, treeState: treeState)
            }
            VStack(spacing: 0) {
                if let scope = model.folderSearchScope {
                    FolderSearchScopeBar(selection: scope,
                                         onSelect: { model.setFolderSearchScope($0, revealSidebar: false) })
                }
                if model.thumbnailView {
                    ThumbnailResultsView(rows: model.results, selectedRecords: model.actionRecords,
                        onSelection: model.selectRecords, onActivate: { ResultActions.open($0) },
                        onPreview: { QuickLookController.shared.toggle($0, allowsNetwork: model.previewAllowsNetwork) },
                        allowsNetwork: model.previewAllowsNetwork, resultList: model.resultList,
                        onVisibleRows: model.setVisibleResults, onOrdering: model.setResultOrdering,
                        selectedRows: model.rowSelection, onRowSelection: model.selectRows, onRowAction: model.performRows)
                } else {
                    ResultsTable(rows: model.results,
                        onSort: { model.setSort($0, ascending: $1) },
                        onSelect: { model.selectedID = $0?.id }, onActivate: { ResultActions.open($0) },
                        onSelection: model.selectRecords,
                        onPreview: { QuickLookController.shared.toggle($0, allowsNetwork: model.previewAllowsNetwork) },
                        selectedRecords: model.actionRecords, query: try? model.featureQueryResult.get(),
                        folderTotals: totals, sortKey: model.sortKey, ascending: model.ascending,
                        showIndexedTotals: model.indexedTotalsColumnOverride,
                        onIndexedTotalsVisibilityChanged: model.indexedColumnsChanged,
                        resultList: model.resultList, onVisibleRows: model.setVisibleResults,
                        onOrdering: model.setResultOrdering, selectedRows: model.rowSelection,
                        onRowSelection: model.selectRows, onRowAction: model.performRows)
                }
            }.frame(minWidth: 250, maxHeight: .infinity)
            if model.previewVisible {
                PreviewPane(records: model.actionRecords, allowsNetwork: model.previewAllowsNetwork)
                    .frame(minWidth: 220, idealWidth: 320, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.refreshFolderDetailsIfNeeded() }
    }
}
