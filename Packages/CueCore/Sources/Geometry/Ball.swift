public enum BallGroup: String, Codable, Sendable, CaseIterable {
    case solids, stripes
    public var other: BallGroup { self == .solids ? .stripes : .solids }
}

/// Ball identity: 0 = cue, 1–15 = object balls.
public struct BallID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let number: Int

    public init?(_ number: Int) {
        guard (0...15).contains(number) else { return nil }
        self.number = number
    }
    private init(unchecked n: Int) { number = n }

    public static let cue = BallID(unchecked: 0)
    public static let eight = BallID(unchecked: 8)
    public static let nine = BallID(unchecked: 9)
    public static let allObjectBalls: [BallID] = (1...15).map { BallID(unchecked: $0) }

    public var isCue: Bool { number == 0 }
    public var group: BallGroup? {
        switch number {
        case 1...7: .solids
        case 9...15: .stripes
        default: nil
        }
    }

    private enum CodingKeys: String, CodingKey { case number }

    /// Decoding enforces the same 0...15 range as `init?(_:)` (peer / persisted payloads are untrusted).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let n = try c.decode(Int.self, forKey: .number)
        guard (0...15).contains(n) else {
            throw DecodingError.dataCorruptedError(forKey: .number, in: c, debugDescription: "BallID \(n) out of 0...15")
        }
        number = n
    }

    public static func < (a: BallID, b: BallID) -> Bool { a.number < b.number }
    public var description: String { isCue ? "cue" : "\(number)" }
}

public enum MotionState: String, Codable, Sendable {
    case stationary, spinning, sliding, rolling, pocketed
}

/// Physical state of one ball. Angular velocity is 3D (x, y in table plane; z = side spin), rad/s.
public struct BallState: Hashable, Codable, Sendable {
    public var position: Vec2
    public var velocity: Vec2
    public var angularVelocity: SIMD3Codable
    public var motion: MotionState

    public init(position: Vec2, velocity: Vec2 = .zero,
                angularVelocity: SIMD3Codable = .zero, motion: MotionState = .stationary) {
        self.position = position
        self.velocity = velocity
        self.angularVelocity = angularVelocity
        self.motion = motion
    }
}

/// Small Codable/Hashable 3-vector (SIMD3 isn't Hashable-Codable friendly across all uses).
public struct SIMD3Codable: Hashable, Codable, Sendable {
    public var x: Double, y: Double, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    public static let zero = SIMD3Codable(0, 0, 0)
}

/// Snapshot of every ball on (or off) the table.
public struct TableState: Hashable, Codable, Sendable {
    public var spec: TableSpec
    public var balls: [BallID: BallState]

    public init(spec: TableSpec, balls: [BallID: BallState] = [:]) {
        self.spec = spec
        self.balls = balls
    }

    public var onTable: [BallID: BallState] { balls.filter { $0.value.motion != .pocketed } }

    private enum CodingKeys: String, CodingKey { case spec, balls }

    /// Same wire shape as the synthesized form (`balls` = flat [key, value, key, value] array), but
    /// encoded in BallID order (byte-stable) and decoded strictly: a duplicate BallID is an error.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(spec, forKey: .spec)
        var arr = c.nestedUnkeyedContainer(forKey: .balls)
        for (id, state) in balls.sorted(by: { $0.key < $1.key }) {
            try arr.encode(id)
            try arr.encode(state)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spec = try c.decode(TableSpec.self, forKey: .spec)
        var arr = try c.nestedUnkeyedContainer(forKey: .balls)
        var balls: [BallID: BallState] = [:]
        while !arr.isAtEnd {
            let id = try arr.decode(BallID.self)
            guard !arr.isAtEnd else {
                throw DecodingError.dataCorruptedError(in: arr, debugDescription: "balls: key \(id) has no value")
            }
            let state = try arr.decode(BallState.self)
            guard balls.updateValue(state, forKey: id) == nil else {
                throw DecodingError.dataCorruptedError(in: arr, debugDescription: "balls: duplicate BallID \(id)")
            }
        }
        self.balls = balls
    }
}
