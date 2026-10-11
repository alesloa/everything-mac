# Third-party notices

`Sources/IndexCore/FuzzyMatcher.swift` adapts the subsequence scoring and
one-edit prefix matching in `fsearch` (`src/query.rs`), copyright (c) 2026
Noah Dunnagan, licensed under MIT. The license is included at
`App/Resources/fsearch-LICENSE.txt` and bundled with the application.

`Sources/IndexCore/UniqueNameIndex.swift` and `UniqueNameSearch.swift` implement
the distinct-filename scoring and grouped character-bitmap approach from
`fsearch` (`src/index.rs` and `src/query.rs`) in Swift. The same MIT license and
reviewed version below apply.

Source: https://github.com/noahdunnagan/fsearch

Reviewed version: `d753915440f0879004b8e11fd615eafc840cfa9c`, vendored by
[FinderSearch](https://github.com/zeusinsight/FinderSearch) at
`c4859909a852e8739be713d8061133203f5ba159`.

EverythingMac remains a Swift application. It does not bundle or launch the
Rust `fsearch` executable. Its immutable search snapshots, Swift integration,
incremental query narrowing, mapped-base/live-overlay storage, background
compaction, and existing substring/glob engine are implemented in this repository.
