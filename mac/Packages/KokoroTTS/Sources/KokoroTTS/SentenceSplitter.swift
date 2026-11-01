import Foundation

/// Splits narration into sentences so the first one can play while the next is synthesized.
public enum SentenceSplitter {
    public static func split(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { out.append(s) }
        }
        // Very short fragments ("Yes." "Check!") sound clipped on their own: glue them to the next sentence.
        var merged: [String] = []
        for s in out {
            if let last = merged.last, last.count < 12 { merged[merged.count - 1] = last + " " + s } else { merged.append(s) }
        }
        return merged.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [text] : merged
    }

    /// Sentences for synthesis, with a long first sentence cut at its first clause break (", ; : —") so the first
    /// audio is ready sooner. Later sentences stay whole for better prosody; they are synthesized while earlier ones play.
    public static func chunks(_ text: String, firstChunkLimit: Int = 48) -> [String] {
        var parts = split(text)
        guard let first = parts.first, first.count > firstChunkLimit else { return parts }
        let breaks: Set<Character> = [",", ";", ":", "\u{2014}"]
        var i = first.startIndex, cut: String.Index?
        while i < first.endIndex {
            let next = first.index(after: i)
            if breaks.contains(first[i]), first.distance(from: first.startIndex, to: i) >= 12,
               first.distance(from: next, to: first.endIndex) >= 12, next < first.endIndex, first[next] == " " {
                cut = next; break
            }
            i = next
        }
        guard let cut else { return parts }
        parts.replaceSubrange(0...0, with: [String(first[..<cut]).trimmingCharacters(in: .whitespaces),
                                            String(first[cut...]).trimmingCharacters(in: .whitespaces)])
        return parts
    }
}
