import UIKit

/// A single-column list with precomputed row heights, and identity-based delta compensation for
/// any content change above the reader.
///
/// Not `UICollectionViewCompositionalLayout` — a hand-rolled `UICollectionViewLayout` gives full
/// control over `targetContentOffset(forProposedContentOffset:)`, which is where prepend and
/// expand/collapse compensation both live (per the `scrolling` skill: "belongs in the layout …
/// not after `performBatchUpdates`, which shows a visible jump on the frame between").
///
/// Row heights are supplied from outside, already measured — this layout never asks a cell for
/// its size and never estimates one. See ``TranscriptCollectionViewController`` for where they
/// come from.
final class TranscriptLayout: UICollectionViewLayout {

    struct Row {
        let id: Int
        let height: Double
    }

    /// The rows to lay out, top to bottom. Setting this alone does nothing until the next
    /// `prepare()` — the caller drives that via `invalidateLayout()`, usually inside
    /// `performBatchUpdates`.
    var rows: [Row] = []
    var interItemSpacing: CGFloat = 12
    var topInset: CGFloat = 12
    var bottomInset: CGFloat = 12
    var horizontalInset: CGFloat = 16

    /// Set immediately before a data change that might move content above the reader — a
    /// prepend, or a card expanding/collapsing. `targetContentOffset(forProposedContentOffset:)`
    /// reads it once, against the *new* layout `prepare()` is about to compute, and clears it.
    var pendingAnchor: (id: Int, offsetTopBeforeUpdate: CGFloat)?

    private var offsetsById: [Int: CGFloat] = [:]
    private var orderedAttributes: [UICollectionViewLayoutAttributes] = []
    private var contentHeight: CGFloat = 0

    private var contentWidth: CGFloat {
        guard let collectionView else { return 0 }
        return collectionView.bounds.width - collectionView.safeAreaInsets.left - collectionView.safeAreaInsets.right
    }

    override func prepare() {
        var offsets: [Int: CGFloat] = [:]
        offsets.reserveCapacity(rows.count)
        var attributes: [UICollectionViewLayoutAttributes] = []
        attributes.reserveCapacity(rows.count)

        var y = topInset
        for (index, row) in rows.enumerated() {
            offsets[row.id] = y
            let attrs = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attrs.frame = CGRect(
                x: horizontalInset, y: y, width: max(0, contentWidth - horizontalInset * 2), height: CGFloat(row.height)
            )
            attributes.append(attrs)
            y += CGFloat(row.height) + interItemSpacing
        }

        offsetsById = offsets
        orderedAttributes = attributes
        // The last row's own trailing spacing was already added by the loop; the bottom inset
        // replaces it rather than stacking on top, so it does not silently grow on every row.
        contentHeight = rows.isEmpty ? topInset + bottomInset : y - interItemSpacing + bottomInset
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: contentWidth, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        orderedAttributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item < orderedAttributes.count else { return nil }
        return orderedAttributes[indexPath.item]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        // A width change (rotation, split view) invalidates because every row's wrap depends on
        // it — the caller is responsible for re-measuring and re-assigning `rows` in response,
        // this only says the *positions* need recomputing once it does.
        guard let collectionView else { return false }
        return newBounds.width != collectionView.bounds.width
    }

    /// Where a row currently sits, from the *last completed* `prepare()` — used both to record a
    /// continuous scroll anchor and, just before mutating `rows`, to seed `pendingAnchor`.
    func offsetTop(forRowId id: Int) -> CGFloat? {
        offsetsById[id]
    }

    /// Corrects by exactly the distance the anchor row moved — never to an absolute position, so
    /// this is correct whether the reader is mid-gesture or not, and correct whether the change
    /// was a prepend (the anchor moves down), an append below the reader (the anchor does not
    /// move, so the delta is zero and nothing shifts), or an expansion above versus below the
    /// anchor (only the first moves it). See the `scrolling` skill's central law.
    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        defer { pendingAnchor = nil }
        guard let anchor = pendingAnchor, let newTop = offsetsById[anchor.id] else { return proposedContentOffset }
        let delta = newTop - anchor.offsetTopBeforeUpdate
        guard delta != 0 else { return proposedContentOffset }
        return CGPoint(x: proposedContentOffset.x, y: proposedContentOffset.y + delta)
    }
}
