import AppKit

/// Fixed-size thumbnail geometry is computed only for the requested viewport.
/// Flow layouts can otherwise retain an attribute object for every indexed file.
@MainActor final class ResultsGridLayout: NSCollectionViewLayout {
    private var width: CGFloat = 1
    private var count = 0
    private var columns: Int { max(1, Int((width - 12) / 168)) }
    private var rows: Int { (count + columns - 1) / columns }

    override func prepare() {
        super.prepare()
        width = max(1, collectionView?.bounds.width ?? 1)
        count = collectionView?.numberOfItems(inSection: 0) ?? 0
    }

    override var collectionViewContentSize: NSSize {
        NSSize(width: width, height: max(collectionView?.enclosingScrollView?.contentView.bounds.height ?? 0,
                                       CGFloat(rows) * 156 + 24))
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        let first = min(rows, max(0, Int(floor((rect.minY - 12) / 156))))
        let last = min(rows, max(first, Int(ceil((rect.maxY - 12) / 156))))
        var attributes: [NSCollectionViewLayoutAttributes] = []
        for row in first..<last {
            for column in 0..<columns {
                let item = row * columns + column
                if item >= count { break }
                if let attribute = layoutAttributesForItem(at: IndexPath(item: item, section: 0)),
                   attribute.frame.intersects(rect) { attributes.append(attribute) }
            }
        }
        return attributes
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section == 0, indexPath.item >= 0, indexPath.item < count else { return nil }
        let attribute = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attribute.frame = NSRect(x: 12 + CGFloat(indexPath.item % columns) * 168,
                                 y: 12 + CGFloat(indexPath.item / columns) * 156, width: 156, height: 144)
        return attribute
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { newBounds.width != width }
}
