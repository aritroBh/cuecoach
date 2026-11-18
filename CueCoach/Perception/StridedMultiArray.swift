import CoreML

/// Element access into a Core ML output that honours its strides. On device the Neural Engine pads rows
/// (stride > logical width), and `MLMultiArray`'s linear subscript is bounded by the logical `count`, so
/// `a[i * stride0 + j * stride1]` raises past the end (device crash 2026-11-08). This reads the backing store directly.
struct StridedMultiArray {
    let shape: [Int]
    let strides: [Int]
    private let read: (Int) -> Double

    /// Calls `body` with a reader valid only inside the closure (the buffer is pinned for its duration).
    static func with<R>(_ a: MLMultiArray, _ body: (StridedMultiArray) -> R) -> R? {
        let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
        let type = a.dataType
        var result: R?
        a.withUnsafeBytes { raw in
            let read: (Int) -> Double
            switch type {
            case .float16: read = { Double(raw.load(fromByteOffset: $0 * 2, as: Float16.self)) }
            case .float32: read = { Double(raw.load(fromByteOffset: $0 * 4, as: Float.self)) }
            case .double: read = { raw.load(fromByteOffset: $0 * 8, as: Double.self) }
            case .int32: read = { Double(raw.load(fromByteOffset: $0 * 4, as: Int32.self)) }
            default: return
            }
            let elementSize = type == .float16 ? 2 : (type == .double ? 8 : 4)
            // The largest offset any in-shape index reaches must lie inside the buffer.
            let maxOffset = zip(shape, strides).reduce(0) { $0 + max($1.0 - 1, 0) * $1.1 }
            guard shape.allSatisfy({ $0 >= 0 }), shape.contains(0) || (maxOffset + 1) * elementSize <= raw.count else { return }
            result = body(StridedMultiArray(shape: shape, strides: strides, read: read))
        }
        return result
    }

    subscript(_ index: Int...) -> Double {
        precondition(index.count == shape.count)
        var off = 0
        for d in 0..<index.count { off += index[d] * strides[d] }
        return read(off)
    }
}
