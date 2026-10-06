import Foundation

/// GFM's extended email autolink, found in linear time — confirmed against `remark-gfm`'s own
/// rendering: a local part of alphanumerics plus `+_.-`, an `@`, and a domain of at least two
/// dot-separated labels of alphanumerics and internal hyphens. No separate trailing-punctuation
/// pass is needed the way the URL branch needs one: the character classes simply do not contain
/// `.`/`,`/`!`/`)` etc. at a position that would trail the match, so GFM's domain-only exception
/// ("a period is part of the address only when another label follows it") falls out of the
/// grammar for free. Not chasing GFM's own further-out quirks (a domain ending in a digit, or a
/// `.` immediately followed by `-`/`_`, are treated inconsistently even between cmark-gfm's own
/// reference implementation and its stated rule).
///
/// Stands in for `[A-Za-z0-9+_.-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+`
/// run through `NSRegularExpression.matches(in:)`, which restarts at every character of a long run
/// of local-part characters and rereads the run to its end looking for an `@`: quadratic in a
/// text node, and a text node can be a pasted blob or text somebody else wrote.
/// `EmailAutolinkScanTests` holds this to that pattern.
///
/// Why anchoring at each `@` gives the same matches:
/// - The local part is a run of local-part characters that must end exactly at an `@`, and `@` is
///   not one of them, so every match is decided by its `@`. The leftmost start is the start of
///   the run ending there, or where the search resumed if that is later: a match ending at the
///   `+` in `a@b.com+x@c.org` leaves `+x` free to start the next one.
/// - In the domain, each label stops at the first character outside `[A-Za-z0-9-]` and ends at
///   the last alphanumeric of that run, so a label that continues into `.` must end exactly there;
///   a trailing `-` stays out of the match and ends the repetition. At least one dotted label has
///   to follow the first.
///
/// Works on UTF-16 units like the engine, and answers in UTF-16 `NSRange`s.
enum EmailAutolinkScan {
    private static func isAlnum(_ u: UInt16) -> Bool {
        (0x30...0x39).contains(u) || (0x41...0x5A).contains(u) || (0x61...0x7A).contains(u)
    }

    private static func isLocal(_ u: UInt16) -> Bool {
        isAlnum(u) || u == 0x2B || u == 0x5F || u == 0x2E || u == 0x2D  // + _ . -
    }

    /// The end of one domain label starting at `from`: the last alphanumeric of its run of
    /// `[A-Za-z0-9-]`, or `nil` when `from` is not an alphanumeric.
    private static func labelEnd(_ text: [UInt16], from: Int) -> Int? {
        guard from < text.count, isAlnum(text[from]) else { return nil }
        var i = from
        var lastAlnum = from
        while i < text.count, isAlnum(text[i]) || text[i] == 0x2D {
            if isAlnum(text[i]) { lastAlnum = i }
            i += 1
        }
        return lastAlnum + 1
    }

    /// The end of the domain starting at `from`, or `nil` when none matches there. A label that
    /// ends in `-` is followed by that `-`, not by a `.`, so the repetition stops on its own.
    private static func domainEnd(_ text: [UInt16], from: Int) -> Int? {
        guard var end = labelEnd(text, from: from) else { return nil }
        var repetitions = 0
        while end < text.count, text[end] == 0x2E, let next = labelEnd(text, from: end + 1) {
            end = next
            repetitions += 1
        }
        return repetitions > 0 ? end : nil
    }

    static func matches(in string: String) -> [NSRange] {
        let text = Array(string.utf16)
        var out: [NSRange] = []
        var resume = 0
        var at = 0
        while at < text.count {
            if text[at] != 0x40 {
                at += 1
                continue
            }
            var start = at
            while start > resume, isLocal(text[start - 1]) { start -= 1 }
            if start < at, let end = domainEnd(text, from: at + 1) {
                out.append(NSRange(location: start, length: end - start))
                resume = end
                at = end
            } else {
                at += 1
            }
        }
        return out
    }
}
