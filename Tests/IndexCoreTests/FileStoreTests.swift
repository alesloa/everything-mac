import Testing
@testable import IndexCore

@Test func storeReconstructsFullPath() {
    var store = FileStore()
    let root = store.append(name: "/", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    let docs = store.append(name: "Docs", parent: root, size: 0, mtime: 0, isDir: true, volID: 1)
    let file = store.append(name: "a.txt", parent: docs, size: 1, mtime: 0, isDir: false, volID: 1)
    #expect(store.path(of: file) == "/Docs/a.txt")
    #expect(store.path(of: root) == "/")
}

@Test func storeAppendsAndCounts() {
    var store = FileStore()
    let root = store.append(name: "", parent: FileStore.noParent, size: 0, mtime: 0, isDir: true, volID: 1)
    let child = store.append(name: "report.pdf", parent: root, size: 2048, mtime: 100, isDir: false, volID: 1)
    #expect(store.count == 2)
    #expect(store.name(of: child) == "report.pdf")
    #expect(store.size(of: child) == 2048)
    #expect(store.isDir(of: root) == true)
}
