import Foundation
import Darwin
import IndexCore

@main struct EverythingCLI {
    static func main() {
        CLISignals.install()
        let output = CLIOutput()
        var failureCode: Int32 = 2
        do {
            let options = try CLIOptions.parse(Array(CommandLine.arguments.dropFirst()))
            switch options.action {
            case .help:
                failureCode = 4
                try output.append(Data(CLIOptions.help.utf8))
            case .version:
                failureCode = 4
                // Source: Sources/IndexCore/IndexCore.swift's published version.
                try output.append(Data((IndexCore.version + "\n").utf8))
            case .search:
                if let error = options.query.validationError { throw error }
                if CLISignals.cancelled { throw CancellationError() }
                failureCode = 3
                let store: FileStore
                do { store = try IndexCache.load(from: options.cacheURL, buildWriterIndex: false).0 }
                catch {
                    // Source: supplied/default cache path and actual IndexCache or
                    // filesystem diagnostic, with no invented error identifier.
                    CLIOutput.diagnostic("\(options.cacheURL.path): \(error.localizedDescription)")
                    exit(CLISignals.cancelled ? CLISignals.exitCode : failureCode)
                }
                failureCode = 4
                let ids = try CatalogSearch.nativeIDs(store: store, query: options.query, sort: options.sort,
                    ascending: options.ascending, limit: options.limit, folderPath: options.folderPath,
                    isCancelled: { CLISignals.cancelled })
                if let format = options.format {
                    let namespace = UUID()
                    try CatalogIO.writeStream(format: format, write: output.append,
                                               isCancelled: { CLISignals.cancelled }) { emit in
                        for id in ids {
                            if CLISignals.cancelled { throw CancellationError() }
                            // Source: IndexCache-loaded FileStore's exact path,
                            // size, mtime and isDir fields. CatalogRecord(native:)
                            // leaves creation dates and native attributes absent.
                            let file = FileRecord(id: id, name: store.name(of: id), path: store.path(of: id),
                                parent: store.parent(of: id), size: store.size(of: id), mtime: store.mtime(of: id),
                                isDir: store.isDir(of: id), volID: store.volID(of: id))
                            try emit(CatalogRecord(native: file, catalogID: namespace))
                        }
                    }
                } else {
                    for id in ids {
                        if CLISignals.cancelled { throw CancellationError() }
                        // Source: FileStore.path(of:) reconstructs the saved name
                        // arena and parent IDs; separators are selected CLI flags.
                        var bytes = Data(store.path(of: id).utf8)
                        bytes.append(options.nullSeparated ? 0 : 10)
                        try output.append(bytes)
                    }
                }
            }
            try output.flush()
            if CLISignals.cancelled { throw CancellationError() }
        } catch CLIWriteError.closedPipe {
            exit(0)
        } catch is CancellationError {
            exit(CLISignals.cancelled ? CLISignals.exitCode : 130)
        } catch {
            // Source: argument validation, shared query/scope parser, catalog
            // serializer or actual POSIX output error from the operation above.
            CLIOutput.diagnostic(error.localizedDescription)
            exit(CLISignals.cancelled ? CLISignals.exitCode : failureCode)
        }
    }
}
