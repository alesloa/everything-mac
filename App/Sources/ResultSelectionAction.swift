import AppKit
import IndexCore

enum ResultSelectionAction {
    case open, reveal, copyPath, copyName, copyFiles, trash, rename, getInfo, copyTo, moveTo
    case openWith(URL)

    @MainActor func perform(_ records: [FileRecord]) {
        switch self {
        case .open: ResultActions.open(records)
        case .reveal: ResultActions.reveal(records)
        case .copyPath: ResultActions.copyPath(records)
        case .copyName: ResultActions.copyName(records)
        case .copyFiles: ResultActions.copyFiles(records)
        case .trash: ResultActions.trash(records)
        case .rename: ResultActions.rename(records)
        case .getInfo: ResultActions.getInfo(records)
        case .copyTo: ResultActions.copyTo(records)
        case .moveTo: ResultActions.moveTo(records)
        case .openWith(let application): ResultActions.open(records, with: application)
        }
    }
}
