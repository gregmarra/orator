import AppKit

/// Pasteboard discipline for the paste insertion path (ORA-INS-005 / ORA-SEC-002).
///
/// The "concealed" type signals clipboard managers that a value is transient and MUST NOT be
/// persisted to disk (ORA-PRIV-003).
public enum Pasteboard {
    /// `org.nspasteboard.ConcealedType` — the community-standard concealed marker honored by
    /// clipboard managers, alongside the OS transient hint.
    public static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// The pasteboard these operations act on. Overridable ONLY so tests can work on a private
    /// pasteboard: they previously wrote fixtures straight to `NSPasteboard.general`, i.e. the user's
    /// real clipboard, and left them there. A dictation's deferred restore then had a stale fixture to
    /// put back, and when that restore beat the host's paste, the fixture was inserted instead of the
    /// dictated text. A test suite must never be able to do that.
    @MainActor static var board: NSPasteboard = .general

    /// A full snapshot of the general pasteboard: every item's every representation (ORA-INS-005).
    public struct Snapshot: Sendable {
        // Each item as [type-string: data]. Captures ALL representations, not just plain string.
        fileprivate let items: [[String: Data]]
    }

    /// Snapshot the entire pasteboard before we clobber it.
    @MainActor
    public static func snapshot() -> Snapshot {
        let pb = board
        let items: [[String: Data]] = (pb.pasteboardItems ?? []).map { item in
            var dict: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type.rawValue] = data }
            }
            return dict
        }
        return Snapshot(items: items)
    }

    /// Write `text` marked concealed/transient. Returns the resulting `changeCount` so callers
    /// can later detect whether anyone (the user) wrote over us.
    @MainActor
    @discardableResult
    public static func writeConcealed(_ text: String) -> Int {
        let pb = board
        pb.clearContents()
        // All markers live on the SAME item as the payload — a separate `setData` before
        // `writeObjects` would land on a different (item 0) and be missed by per-item readers.
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: concealedType)   // presence marks it concealed
        item.setData(Data(), forType: transientType)   // and transient (don't persist to disk)
        pb.writeObjects([item])
        return pb.changeCount
    }

    /// Restore a snapshot, but ONLY if the pasteboard hasn't advanced beyond `expectedChangeCount`
    /// (the value we wrote) — if the user copied in the meantime we MUST NOT clobber the newer
    /// clipboard (ORA-INS-005 / E13). Returns true if the restore was performed.
    @MainActor
    @discardableResult
    public static func restore(_ snapshot: Snapshot, ifUnchangedFrom expectedChangeCount: Int) -> Bool {
        let pb = board
        guard pb.changeCount == expectedChangeCount else { return false }  // user copied — leave it
        pb.clearContents()
        let items: [NSPasteboardItem] = snapshot.items.map { rep in
            let item = NSPasteboardItem()
            for (type, data) in rep {
                item.setData(data, forType: .init(type))
            }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
        return true
    }
}
