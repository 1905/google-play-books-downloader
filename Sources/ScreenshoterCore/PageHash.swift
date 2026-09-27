/// 256-bit difference hash (16×16 dHash).
public struct PageHash: Equatable {
    /// Always 4 words; bit `i` of the hash is bit `i % 64` of `words[i / 64]`.
    public let words: [UInt64]

    /// Resizes to 17×16; bit is set when a pixel is darker than its right neighbour.
    public init(_ image: GrayImage) {
        let small = image.resized(width: 17, height: 16)
        var words = [UInt64](repeating: 0, count: 4)
        for y in 0..<16 {
            for x in 0..<16 where small[x, y] < small[x + 1, y] {
                let bit = y * 16 + x
                words[bit / 64] |= 1 << UInt64(bit % 64)
            }
        }
        self.words = words
    }

    /// Hamming distance.
    public func distance(to other: PageHash) -> Int {
        zip(words, other.words).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
    }
}
