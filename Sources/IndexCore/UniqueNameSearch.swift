import Foundation

extension QueryEngine {
    // The snapshot supplies its reusable dictionary. Restricted candidate sets
    // and full-path searches retain their ordinary per-record semantics.
    func search(_ query: Query, in store: FileStore, candidates: [UInt32]? = nil,
                nameIndex: UniqueNameIndex?,
                isCancelled: @escaping @Sendable () -> Bool = { false }) -> [UInt32] {
        guard !isCancelled() else { return [] }
        if query.hasFuzzyTerms {
            return matches(query, in: store, candidates: candidates, nameIndex: nameIndex,
                           isCancelled: isCancelled).map(\.id)
        }
        guard let nameIndex, candidates == nil, !query.matchPath, !query.terms.isEmpty else {
            return search(query, in: store, candidates: candidates, isCancelled: isCancelled)
        }
        let terms = query.terms.map { ($0, query.caseInsensitive ? Glob.asciiLowerBytes($0) : nil) }
        let requirements = terms.map { term -> UniqueNameIndex.Requirement in
            let mask = term.1.map { FuzzyMatcher.mask($0.filter { $0 != 42 && $0 != 63 }) } ?? 0
            return .init(mask: mask, allowsMissingCharacter: false, firstCharacter: 0)
        }
        var all: [UInt32] = []
        for layer in nameIndex.layers {
            if isCancelled() { return [] }
            let scored: [UInt32] = searchParts(count: layer.groupCount, parallelThreshold: 1563,
                                             isCancelled: isCancelled) { lo, hi in
                // Workers own their pattern buffers, avoiding per-name shared ARC.
                let localTerms = terms.map { ($0.0, $0.1?.map { $0 }) }
                return store.withNameArena { arena in
                    var matches: [UInt32] = []
                    for group in lo..<hi {
                        if group & 15 == 0 && isCancelled() { return [] }
                        var names = layer.candidates(in: group, requirements: requirements)
                        while names != 0 {
                            let nameID = group * 64 + names.trailingZeroBitCount
                            names &= names - 1
                            let id = layer.representatives[nameID]
                            let bytes = arena.bytes(in: store.nameRange(of: id))
                            var string: String?
                            var fits = true
                            for (term, ascii) in localTerms {
                                if let ascii {
                                    if !Glob.matchesASCII(patternLowerBytes: ascii, in: bytes) { fits = false; break }
                                } else {
                                    if string == nil { string = store.name(of: id) }
                                    if !Glob.matches(pattern: term, in: string!, caseInsensitive: query.caseInsensitive) {
                                        fits = false; break
                                    }
                                }
                                if query.wholeWord && !term.contains("*") && !term.contains("?") {
                                    if string == nil { string = store.name(of: id) }
                                    if !Glob.containsWholeWord(term, in: string!, caseInsensitive: query.caseInsensitive) {
                                        fits = false; break
                                    }
                                }
                            }
                            if fits { matches.append(UInt32(nameID)) }
                        }
                    }
                    return matches
                }
            }
            guard !isCancelled() else { return [] }
            if scored.isEmpty { continue }
            var names = [Bool](repeating: false, count: layer.representatives.count)
            for name in scored { names[Int(name)] = true }
            let matchedNames = names
            let expanded: [UInt32] = searchParts(count: layer.recordNames.count, parallelThreshold: 100_000,
                                               isCancelled: isCancelled) { lo, hi in
                var ids: [UInt32] = []
                let checkLive = store.hasDeletions
                for offset in lo..<hi {
                    if offset & 1023 == 0 && isCancelled() { return [] }
                    if !matchedNames[Int(layer.recordNames[offset])] { continue }
                    let id = UInt32(layer.recordRange.lowerBound + offset)
                    if !checkLive || store.isLive(id) { ids.append(id) }
                }
                return ids
            }
            all.append(contentsOf: expanded)
        }
        return isCancelled() ? [] : all
    }
}
