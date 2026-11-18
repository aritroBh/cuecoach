import CoreML
import Foundation
import Testing
@testable import CueCoach

/// Device crash 2026-11-08 (iPhone 17 Pro Max, every live session): the ANE hands back output arrays whose rows are
/// padded (stride > logical width). Linear `MLMultiArray[i]` subscripts are bounded by `count` (the logical size), so
/// `a[i * stride1 + j * stride2]` ran past the end and Core ML raised in `numberAtOffset`. The simulator's CPU path is
/// contiguous, so nothing caught it. Readers must address elements by stride in the backing store.
struct StridedMultiArrayTests {
    /// A `shape` array whose last axis is padded to `rowPad` elements, filled with `value(index)`; padding is NaN.
    static func padded(shape: [Int], rowPad: Int, type: MLMultiArrayDataType,
                       value: ([Int]) -> Double) throws -> MLMultiArray {
        precondition(rowPad >= shape.last!)
        var strides = [Int](repeating: 1, count: shape.count)
        strides[shape.count - 1] = 1
        if shape.count >= 2 { strides[shape.count - 2] = rowPad }
        if shape.count >= 3 { for d in stride(from: shape.count - 3, through: 0, by: -1) { strides[d] = strides[d + 1] * shape[d + 1] } }
        let total = strides[0] * shape[0]
        let elementSize = type == .float16 ? 2 : (type == .double ? 8 : 4)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: total * elementSize, alignment: 16)
        func store(_ off: Int, _ v: Double) {
            switch type {
            case .float16: raw.storeBytes(of: Float16(v), toByteOffset: off * 2, as: Float16.self)
            case .double: raw.storeBytes(of: v, toByteOffset: off * 8, as: Double.self)
            default: raw.storeBytes(of: Float(v), toByteOffset: off * 4, as: Float.self)
            }
        }
        for off in 0..<total { store(off, .nan) }
        func walk(_ prefix: [Int]) {
            if prefix.count == shape.count {
                store(zip(prefix, strides).map { $0 * $1 }.reduce(0, +), value(prefix)); return
            }
            for i in 0..<shape[prefix.count] { walk(prefix + [i]) }
        }
        walk([])
        return try MLMultiArray(dataPointer: raw, shape: shape.map { NSNumber(value: $0) }, dataType: type,
                                strides: strides.map { NSNumber(value: $0) }, deallocator: { $0.deallocate() })
    }

    @Test(arguments: [MLMultiArrayDataType.float16, .float32])
    func keypointRowsReadThroughPaddedStrides(type: MLMultiArrayDataType) throws {
        // [1, 300, 36] with rows padded to 48: row 7 is the best detection (conf 0.9); keypoint k = (k, k + 0.5, 0.75).
        let a = try Self.padded(shape: [1, 300, 36], rowPad: 48, type: type) { idx in
            let (i, j) = (idx[1], idx[2])
            if j == 4 { return i == 7 ? 0.9 : (i == 3 ? 0.4 : 0.01) }
            guard i == 7, j >= 6 else { return 0 }
            let k = (j - 6) / 3
            return [Double(k), Double(k) + 0.5, 0.75][(j - 6) % 3]
        }
        let rows = try #require(CoreMLTableKeypointProvider.bestRows(a, minConfidence: 0.35))
        #expect(rows.count == 10)
        for (k, r) in rows.enumerated() {
            #expect(abs(r.x - Double(k)) < 0.01 && abs(r.y - (Double(k) + 0.5)) < 0.01 && abs(r.z - 0.75) < 0.01)
        }
    }

    @Test func keypointRowsNilWhenNothingConfident() throws {
        let a = try Self.padded(shape: [1, 50, 36], rowPad: 40, type: .float16) { $0[2] == 4 ? 0.1 : 0 }
        #expect(CoreMLTableKeypointProvider.bestRows(a, minConfidence: 0.35) == nil)
    }

    @Test(arguments: [MLMultiArrayDataType.float16, .float32])
    func ballRowsReadThroughPaddedStrides(type: MLMultiArrayDataType) throws {
        // NMS outputs: confidence [3, 80] padded to 96, coordinates [3, 4] padded to 8.
        let conf = try Self.padded(shape: [3, 80], rowPad: 96, type: type) { idx in
            idx[1] == idx[0] + 2 ? 0.8 : (idx[1] >= 16 ? 0.99 : 0)
        }
        let coords = try Self.padded(shape: [3, 4], rowPad: 8, type: type) { idx in Double(idx[0]) * 0.1 + Double(idx[1]) * 0.01 }
        let (c, b) = try #require(CoreMLBallInference.copyRows(confidence: conf, coordinates: coords))
        #expect(c.count == 3 * BallDetectorOutput.classCount && b.count == 12)
        for i in 0..<3 {
            let k = BallDetectorOutput.classCount
            for j in 0..<k {
                let want: Float = j == i + 2 ? 0.8 : 0
                #expect(abs(c[i * k + j] - want) < 0.01)
            }
            for j in 0..<4 {
                let want = Float(i) * 0.1 + Float(j) * 0.01
                #expect(abs(b[i * 4 + j] - want) < 0.01)
            }
        }
    }

    @Test func ballRowsEmptyWhenNoDetections() throws {
        let conf = try MLMultiArray(shape: [0, 80], dataType: .float32)
        let coords = try MLMultiArray(shape: [0, 4], dataType: .float32)
        let (c, b) = try #require(CoreMLBallInference.copyRows(confidence: conf, coordinates: coords))
        #expect(c.isEmpty && b.isEmpty)
    }
}
