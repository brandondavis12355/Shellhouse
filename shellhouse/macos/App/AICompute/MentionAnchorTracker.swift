import Foundation

/// Tracks which occurrence of `trigger` (`@` for a mention, `/` for a
/// skill command) in a growing/shrinking text field is currently active
/// — by plain INTEGER offset, diffed from consecutive
/// `.onChange(of: text)` snapshots. Deliberately NOT built on
/// `String.Index`/SwiftUI's `TextSelection`: that was tried first, and
/// reverted after it crashed ("String index range is out of bounds")
/// once its cached indices went stale relative to the live text — a
/// framework fragility, not something this app could reliably patch
/// around. Every position derived here is re-validated against the
/// CURRENT string via `String.index(_:offsetBy:limitedBy:)`, which
/// returns `nil` instead of trapping when out of bounds, so a bug in
/// this tracking logic can only ever mean "no suggestion right now,"
/// never a crash.
///
/// This is what lets `@`/`/` work correctly even typed into the middle
/// of existing text (the original bug this whole thing chases): the
/// tracked trigger is whichever one was ACTUALLY just typed, identified
/// by diffing, not "the last `@`" or "does the whole string start with
/// `/`" — so an unrelated `@`/`/` elsewhere never gets mistaken for this
/// one. The filter query itself is then always the run of non-space
/// characters immediately connected to the trigger's right, scanned
/// fresh from the CURRENT text on every access — so it picks up letters
/// already sitting there (e.g. typing `@` right before an existing
/// word) exactly the same way it picks up letters typed after the
/// trigger, with no separate "how much have I typed since" bookkeeping.
struct MentionAnchorTracker {
    let trigger: Character
    /// `/` commands must lead the whole message (this app's existing
    /// convention — a slash command isn't embeddable mid-sentence the
    /// way `@mentions` are), so a tracker built with this `true` only
    /// ever arms on a `trigger` typed at offset 0, and anywhere else is
    /// treated as ordinary text instead of a false command start.
    let requiresStartOfText: Bool
    private(set) var anchorOffset: Int?

    init(trigger: Character, requiresStartOfText: Bool = false) {
        self.trigger = trigger
        self.requiresStartOfText = requiresStartOfText
    }

    /// Call from `.onChange(of: text)` with the field's old and new
    /// value, on every change for any reason. Only a single-character
    /// insert or delete is tracked; anything else (paste, a suggestion
    /// tap overwriting part of the field, `submitInput()` clearing it
    /// entirely) just drops whatever was in progress — the suggestion
    /// list disappears rather than risk misplacing it.
    mutating func handleChange(old: String, new: String) {
        if new.count == old.count + 1 {
            handleInsert(old: old, new: new)
        } else if new.count == old.count - 1 {
            handleDelete(old: old, new: new)
        } else {
            reset()
        }
    }

    mutating func reset() {
        anchorOffset = nil
    }

    /// The current filter query: the run of non-space characters right
    /// after the tracked trigger, in `text` right now — `nil` if nothing
    /// is being tracked, it no longer resolves against `text`, or the
    /// trigger itself is immediately followed by a space (finished, not
    /// a live query anymore).
    func query(in text: String) -> String? {
        guard let range = triggerRange(in: text) else { return nil }
        return text[range.query].lowercased()
    }

    /// The full `<trigger>query` span (including the trigger itself) to
    /// replace when a suggestion is chosen — `nil` under the same
    /// conditions as `query(in:)`.
    func replacementRange(in text: String) -> Range<String.Index>? {
        triggerRange(in: text)?.full
    }

    private func triggerRange(in text: String) -> (full: Range<String.Index>, query: Range<String.Index>)? {
        guard let anchorOffset,
              !requiresStartOfText || anchorOffset == 0,
              let triggerIndex = text.index(text.startIndex, offsetBy: anchorOffset, limitedBy: text.endIndex),
              triggerIndex < text.endIndex, text[triggerIndex] == trigger
        else { return nil }
        var queryEnd = text.index(after: triggerIndex)
        while queryEnd < text.endIndex, text[queryEnd] != " " {
            queryEnd = text.index(after: queryEnd)
        }
        return (triggerIndex..<queryEnd, text.index(after: triggerIndex)..<queryEnd)
    }

    private mutating func handleInsert(old: String, new: String) {
        let prefixLen = zip(old, new).prefix { $0 == $1 }.count
        let suffixLen = zip(old.reversed(), new.reversed()).prefix { $0 == $1 }.count
        guard prefixLen + suffixLen >= old.count else { reset(); return }
        let insertPos = prefixLen
        let insertedChar = new[new.index(new.startIndex, offsetBy: insertPos)]

        if insertedChar == trigger, !requiresStartOfText || insertPos == 0 {
            anchorOffset = insertPos
            return
        }
        guard let anchor = anchorOffset else { return }
        if insertPos <= anchor {
            // Inserted before (or exactly at) the tracked trigger —
            // pushes it forward. Anything inserted AFTER it just
            // becomes part of the query on the next read — nothing to
            // update here, since the query is always scanned fresh.
            anchorOffset = anchor + 1
        }
    }

    private mutating func handleDelete(old: String, new: String) {
        let prefixLen = zip(old, new).prefix { $0 == $1 }.count
        let suffixLen = zip(old.reversed(), new.reversed()).prefix { $0 == $1 }.count
        guard prefixLen + suffixLen >= new.count else { reset(); return }
        let removePos = prefixLen
        guard let anchor = anchorOffset else { return }
        if removePos == anchor {
            reset()
        } else if removePos < anchor {
            anchorOffset = anchor - 1
        }
    }
}
