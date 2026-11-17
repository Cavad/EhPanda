public import CoreGraphics

/// Reconciles a visible gallery when refresh or filtering changes the collection.
public enum GalleryScrollAnchor {
    /// How far a row may sit past an edge of the clear area before it counts as covered.
    static let edgeTolerance: CGFloat = 1

    public static func retaining(_ id: String?, previousIDs: [String], currentIDs: [String]) -> String? {
        guard let id else { return nil }
        guard !currentIDs.contains(id) else { return id }
        guard let previousIndex = previousIDs.firstIndex(of: id) else { return currentIDs.first }
        let remaining = Set(currentIDs)
        var closestID: String?
        var closestDistance = Int.max
        for (offset, candidate) in previousIDs.enumerated() where remaining.contains(candidate) {
            let distance = abs(offset - previousIndex)
            if distance < closestDistance {
                closestDistance = distance
                closestID = candidate
            }
        }
        return closestID ?? currentIDs.first
    }

    /// The gallery a person sees first: the highest row whose center lies inside the clear area,
    /// the list's frame minus the navigation and tab bars. A row mostly covered by a bar never qualifies.
    public static func topVisibleID(rowFrames: [String: CGRect], clearArea: CGRect) -> String? {
        topVisibleID(in: rowFrames, clearArea: clearArea)
    }

    static func topVisibleID(
        in rowFrames: [String: CGRect], clearArea: CGRect, visibleRows: Set<String>? = nil
    ) -> String? {
        var topID: String?
        var topY = CGFloat.infinity
        for (id, frame) in rowFrames {
            guard visibleRows?.contains(id) != false,
                  frame.midY >= clearArea.minY, frame.midY < clearArea.maxY
            else { continue }
            if frame.minY < topY || (frame.minY == topY && topID.map({ id < $0 }) != false) {
                topID = id
                topY = frame.minY
            }
        }
        return topID
    }

    /// Whether a restored row is complete inside the clear area, or still needs the list to reveal it.
    public static func isUncovered(rowFrame: CGRect, clearArea: CGRect) -> Bool {
        rowFrame.minY >= clearArea.minY - edgeTolerance && rowFrame.maxY <= clearArea.maxY + edgeTolerance
    }
}
