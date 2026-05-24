import Foundation

// MARK: - Safe collection helpers
//
// Swift's standard `prefix(_:)`, `dropFirst(_:)`, and subscript operators are
// safe for valid inputs but will produce undefined behaviour or crash when
// counts are negative or exceed the collection's size in edge cases that arise
// during proactivity flood scenarios (e.g. 464 articles inserted at once).
//
// These wrappers provide defensive alternatives with the same semantics but
// without the crash surface.

// MARK: - Collection helpers

extension Collection {
    /// Returns up to `count` elements from the start of the collection.
    ///
    /// Unlike `prefix(_:)`, this is always safe:
    /// - Negative `count` returns an empty slice.
    /// - `count` larger than `self.count` returns the entire collection.
    func safePrefix(_ count: Int) -> SubSequence {
        guard count > 0 else { return self[startIndex..<startIndex] }
        return prefix(Swift.min(count, self.count))
    }

    /// Returns up to `count` elements from the end of the collection.
    ///
    /// Unlike `suffix(_:)`, this is always safe:
    /// - Negative `count` returns an empty slice.
    /// - `count` larger than `self.count` returns the entire collection.
    func safeSuffix(_ count: Int) -> SubSequence {
        guard count > 0 else { return self[endIndex..<endIndex] }
        return suffix(Swift.min(count, self.count))
    }

    /// Returns the element at `index`, or nil if out of bounds.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Array helpers

extension Array {
    /// Returns the array with the first `count` elements removed.
    ///
    /// Unlike `dropFirst(_:)`, this is always safe:
    /// - Negative `count` returns a copy of the array.
    /// - `count` larger than `self.count` returns an empty array.
    func safeDropFirst(_ count: Int) -> [Element] {
        guard count > 0 else { return self }
        return Array(dropFirst(Swift.min(count, self.count)))
    }

    /// Removes the first `count` elements in-place.
    ///
    /// Unlike `removeFirst(_:)`, this is always safe:
    /// - Negative `count` is a no-op.
    /// - `count` larger than `self.count` clears the array.
    mutating func safeRemoveFirst(_ count: Int) {
        guard count > 0 else { return }
        removeFirst(Swift.min(count, self.count))
    }

    /// Returns the array with the last `n` elements removed.
    ///
    /// Unlike `dropLast(_:)`, this is always safe:
    /// - `n <= 0` returns the full array.
    /// - `n >= count` returns an empty array.
    func droppingLast(_ n: Int) -> [Element] {
        guard n > 0, count > n else { return n >= count ? [] : self }
        return Array(dropLast(n))
    }

    /// Splits the array into consecutive batches of at most `size` elements.
    ///
    /// - Parameter size: Maximum elements per batch. Must be ≥ 1; values
    ///   below 1 are treated as 1 to prevent infinite loops.
    /// - Returns: An array of sub-arrays; empty if `self` is empty.
    func safeBatch(size: Int) -> [[Element]] {
        let batchSize = Swift.max(size, 1)
        var batches: [[Element]] = []
        var index = 0
        while index < self.count {
            let end = Swift.min(index + batchSize, self.count)
            batches.append(Array(self[index..<end]))
            index = end
        }
        return batches
    }
}

// MARK: - String helpers

extension String {
    /// Returns the string truncated to at most `maxLength` characters.
    ///
    /// If the string is already shorter than `maxLength`, it is returned
    /// unchanged.  `maxLength` values ≤ 0 return an empty string.
    func safelyTruncated(to maxLength: Int) -> String {
        guard maxLength > 0 else { return "" }
        guard self.count > maxLength else { return self }
        return String(prefix(maxLength))
    }

    /// Trims whitespace/newlines from both ends, then truncates to `maxLength`.
    ///
    /// Returns `""` when the string is empty or `maxLength` ≤ 0.
    func safePreview(_ maxLength: Int = 160) -> String {
        guard maxLength > 0 else { return "" }
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.safelyTruncated(to: maxLength)
    }
}
