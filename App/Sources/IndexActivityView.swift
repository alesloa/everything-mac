import SwiftUI
import IndexCore

/// Sources: all values come from IndexActor's memory-only activity snapshot;
/// static labels describe this viewer's filters, recorded outcomes and controls.
struct IndexActivityView: View {
    let index: IndexActor
    @State private var snapshot: IndexActivitySnapshot
    @State private var category: IndexActivityCategory?
    @State private var root = ""
    @State private var filter = ""
    @State private var paused = false
    @State private var selection: UInt64?

    init(index: IndexActor) {
        self.index = index
        _snapshot = State(initialValue: index.activitySnapshot())
    }

    private var events: [IndexActivityEvent] {
        snapshot.events(category: category, root: root.isEmpty ? nil : root, containing: filter).reversed()
    }

    private var selectedEvent: IndexActivityEvent? { snapshot.events.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Activity", selection: $category) {
                    Text("All activity").tag(IndexActivityCategory?.none)
                    ForEach(IndexActivityCategory.allCases, id: \.self) { category in
                        Text(category.rawValue).tag(Optional(category))
                    }
                }
                .frame(width: 220)
                Picker("Scope", selection: $root) {
                    Text("All paths").tag("")
                    ForEach(snapshot.indexedRoots, id: \.self) { path in Text(path).tag(path) }
                }
                .frame(width: 240)
                TextField("Filter recorded activity", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Button(paused ? "Resume" : "Pause") {
                    paused.toggle()
                    if !paused { refresh() }
                }
                Button("Clear") {
                    index.clearActivity()
                    selection = nil
                    refresh()
                }
                .disabled(snapshot.events.isEmpty)
                .help("Clear recorded entries; keep the current index and scan status.")
            }
            .padding(12)
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        indexStatus
                        scanStatus
                        cacheStatus
                        shareStatus
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 230, idealWidth: 270, maxWidth: 350)

                VStack(spacing: 0) {
                    Table(events, selection: $selection) {
                        TableColumn("Time") { event in
                            Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                .monospacedDigit()
                        }
                        .width(85)
                        TableColumn("Observation") { event in Text(event.kind.label) }
                            .width(min: 145, ideal: 165)
                        TableColumn("Path") { event in
                            Text(event.path).lineLimit(1).truncationMode(.middle)
                                .help(event.path)
                        }
                        TableColumn("Details") { event in
                            Text(eventDetail(event)).lineLimit(1).help(eventDetail(event))
                        }
                    }
                    .overlay {
                        if events.isEmpty {
                            ContentUnavailableView("No recorded activity", systemImage: "list.bullet.rectangle",
                                description: Text(snapshot.events.isEmpty
                                    ? "Activity appears as indexing and cache operations are observed."
                                    : "No recorded entries match these filters."))
                        }
                    }
                    Divider()
                    if let event = selectedEvent {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(event.kind.label) · \(event.timestamp.formatted(date: .abbreviated, time: .standard))")
                                .font(.headline)
                            Text(event.path).font(.system(.body, design: .monospaced))
                            if !eventDetail(event).isEmpty { Text(eventDetail(event)) }
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    }
                    HStack {
                        Text("\(snapshot.events.count.formatted()) retained · \(snapshot.capacity.formatted()) limit")
                        if snapshot.droppedEventCount > 0 {
                            Text("\(snapshot.droppedEventCount.formatted()) older entries overwritten")
                        }
                        Spacer()
                        if paused { Text("Display paused") }
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(10)
                }
                .frame(minWidth: 570)
            }
            Divider()
            // Source: LiveMonitor uses directory events and its existing mtime gate;
            // the observer reports direct diffs without verified rename/move pairs.
            Text("This session records observed index additions and removals, metadata differences found during directory reconciliation, scan outcomes, and cache operations. Directory events do not identify rename or move pairs. Excluded entries are not individually recorded.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(minWidth: 920, minHeight: 540)
        .task {
            refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                if !paused { refresh() }
            }
        }
    }

    private var indexStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Published index").font(.headline)
            Text("\(snapshot.indexedCount.formatted()) objects").monospacedDigit()
            if !snapshot.indexedRoots.isEmpty {
                Text("Indexed roots").font(.caption).foregroundStyle(.secondary)
                ForEach(snapshot.indexedRoots, id: \.self) { path in
                    Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
    }

    private var scanStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Active scans").font(.headline)
            if snapshot.activeScans.isEmpty { Text("None").foregroundStyle(.secondary) }
            ForEach(snapshot.activeScans) { scan in
                VStack(alignment: .leading, spacing: 4) {
                    Text(scan.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if let count = scan.observedCount {
                        Text("\(count.formatted()) objects reported").monospacedDigit()
                    } else { Text("No progress reported").foregroundStyle(.secondary) }
                    Text("Started \(scan.startedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var cacheStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Index cache").font(.headline)
            if let path = snapshot.cache.path {
                Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            if let operation = snapshot.cache.lastOperation {
                Text(operation.label)
            } else { Text("No operation recorded").foregroundStyle(.secondary) }
            if let detail = snapshot.cache.detail { Text(detail).font(.caption).textSelection(.enabled) }
            if let count = snapshot.cache.byteCount { Text("Last measured: \(count.formatted()) bytes").monospacedDigit() }
            if let date = snapshot.cache.modifiedAt { statusDate("File modified", date) }
            if let date = snapshot.cache.lastLoadedAt { statusDate("Loaded", date) }
            if let date = snapshot.cache.lastSavedAt { statusDate("Saved", date) }
        }
    }

    private var shareStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Network shares").font(.headline)
            if snapshot.shares.isEmpty { Text("None configured").foregroundStyle(.secondary) }
            ForEach(snapshot.shares) { share in
                VStack(alignment: .leading, spacing: 4) {
                    Text(share.name).font(.subheadline.bold())
                    Text(share.mountPath == nil ? "Offline" : "Mounted")
                    if let path = share.mountPath ?? share.indexedPath {
                        Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    if let count = share.indexedCount {
                        Text("\(count.formatted()) indexed objects").monospacedDigit()
                    } else { Text("No count recorded").foregroundStyle(.secondary) }
                    if share.scanning { Text("Scanning") }
                    if let count = share.observedCount { Text("\(count.formatted()) objects reported by scan") }
                    if share.queued { Text("Refresh queued") }
                    if share.paused { Text("Automatic refresh paused") }
                    if let date = share.lastRefreshed { statusDate("Refreshed", date) }
                }
                .padding(.bottom, 6)
            }
        }
    }

    private func statusDate(_ label: String, _ date: Date) -> some View {
        Text("\(label) \(date.formatted(date: .abbreviated, time: .standard))")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func eventDetail(_ event: IndexActivityEvent) -> String {
        if let metadata = event.metadata {
            // Source: the journal retains the original indexed/fstatat metadata without extra filesystem reads.
            let prior = Date(timeIntervalSince1970: TimeInterval(metadata.priorModificationTime))
                .formatted(date: .abbreviated, time: .standard)
            let observed = Date(timeIntervalSince1970: TimeInterval(metadata.modificationTime))
                .formatted(date: .abbreviated, time: .standard)
            return "Indexed: \(metadata.priorSize.formatted()) bytes, \(prior). Observed: \(metadata.size.formatted()) bytes, \(observed)."
        }
        if let count = event.count {
            let objects = "\(count.formatted()) objects in result"
            return event.detail.map { objects + " · " + $0 } ?? objects
        }
        return event.detail ?? ""
    }

    private func refresh() {
        let next = index.activitySnapshot()
        if snapshot.revision != next.revision { snapshot = next }
        if !root.isEmpty, !snapshot.indexedRoots.contains(root) { root = "" }
        if let selection, !snapshot.events.contains(where: { $0.id == selection }) { self.selection = nil }
    }
}
