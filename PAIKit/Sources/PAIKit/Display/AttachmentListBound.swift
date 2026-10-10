/// How much of an attachment list is drawn before the rest sit behind a "+N" control.
///
/// A message may carry any number of files, and both places that draw them — the composer's
/// strip and a sent message in the transcript — show only the first few and open the whole list
/// from the control. The transcript's row heights are precomputed, so the number of rows its
/// attachment column draws is the one fact the view and ``TranscriptRowLayout`` must agree on;
/// it is answered here once.
public enum AttachmentListBound {
    /// Previews the composer strip draws before its "+N" tile.
    public static let composerVisible = 5
    /// Chips a sent message draws before its "+N more" row.
    public static let transcriptVisible = 3

    /// How many of `total` a list bounded to `limit` draws.
    public static func visibleCount(total: Int, limit: Int) -> Int {
        min(total, limit)
    }

    /// How many sit behind the control.
    public static func hiddenCount(total: Int, limit: Int) -> Int {
        max(0, total - limit)
    }

    /// The rows a sent message's attachment column occupies: the visible chips, plus one row of
    /// the same height for the "+N more" control when anything is hidden.
    public static func transcriptRowCount(total: Int) -> Int {
        visibleCount(total: total, limit: transcriptVisible)
            + (hiddenCount(total: total, limit: transcriptVisible) > 0 ? 1 : 0)
    }
}
