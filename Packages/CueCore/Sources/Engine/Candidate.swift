import Geometry
import Physics
import Rules

/// What kind of shot a candidate is (engine.md §12, RATINGS §2).
public enum ShotKind: Hashable, Codable, Sendable {
    /// Cue ball → object ball → pocket.
    case direct
    /// Object ball off one rail into the pocket.
    case bank(Rail)
    /// Cue ball off one rail first. With a pocket it is a kick-pot; without, a kick to get a legal hit.
    case kick(Rail)
    /// Two-ball combination: the cue ball hits `target`, which pockets `via` (the second ball).
    case combo(via: BallID)
    /// Defensive shot: legal hit, aim to leave the opponent nothing.
    case safety
    /// WPA 9-ball push-out (5.4).
    case pushOut
    /// Opening break (always Book, D18 row 1).
    case breakShot

    /// Offensive = intends to pocket a ball.
    public var isOffensive: Bool {
        switch self {
        case .direct, .bank, .combo: true
        case .kick, .safety, .pushOut, .breakShot: false
        }
    }
    public var isBook: Bool { self == .pushOut || self == .breakShot }
}

/// One shot option. `stroke.speed` is always one of the 5 power-meter steps (engine.md §4.2).
public struct Candidate: Hashable, Sendable {
    /// Stable index within one `generate` call; tie-breaks and RNG streams.
    public var id: UInt32
    public var kind: ShotKind
    /// Ball the cue ball is meant to hit first (nil for push-outs).
    public var target: BallID?
    /// Ball meant to drop (nil for safeties, hit-kicks, push-outs, breaks).
    public var objectBall: BallID?
    public var pocket: Pocket?
    public var stroke: Stroke
    /// Power meter step 1…5.
    public var meterStep: Int
    /// Where to put the cue ball when the shooter has ball in hand.
    public var cuePlacement: Vec2?
    /// Ghost-ball position (overlay).
    public var ghost: Vec2?

    public init(id: UInt32, kind: ShotKind, target: BallID?, objectBall: BallID?, pocket: Pocket?,
                stroke: Stroke, meterStep: Int, cuePlacement: Vec2? = nil, ghost: Vec2? = nil) {
        self.id = id
        self.kind = kind
        self.target = target
        self.objectBall = objectBall
        self.pocket = pocket
        self.stroke = stroke
        self.meterStep = meterStep
        self.cuePlacement = cuePlacement
        self.ghost = ghost
    }

    /// Pot attempts (offence, or a kick at a pocket).
    public var intendsPot: Bool { objectBall != nil && pocket != nil }
}

extension Candidate: Codable {
    enum CodingKeys: String, CodingKey {
        case id, kind, target, objectBall, pocket, direction, speed, tipOffset, meterStep, cuePlacement, ghost
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UInt32.self, forKey: .id), kind: try c.decode(ShotKind.self, forKey: .kind),
                  target: try c.decodeIfPresent(BallID.self, forKey: .target),
                  objectBall: try c.decodeIfPresent(BallID.self, forKey: .objectBall),
                  pocket: try c.decodeIfPresent(Pocket.self, forKey: .pocket),
                  stroke: Stroke(direction: try c.decode(Vec2.self, forKey: .direction),
                                 speed: try c.decode(Double.self, forKey: .speed),
                                 tipOffset: try c.decode(Vec2.self, forKey: .tipOffset)),
                  meterStep: try c.decode(Int.self, forKey: .meterStep),
                  cuePlacement: try c.decodeIfPresent(Vec2.self, forKey: .cuePlacement),
                  ghost: try c.decodeIfPresent(Vec2.self, forKey: .ghost))
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(target, forKey: .target)
        try c.encodeIfPresent(objectBall, forKey: .objectBall)
        try c.encodeIfPresent(pocket, forKey: .pocket)
        try c.encode(stroke.direction, forKey: .direction)
        try c.encode(stroke.speed, forKey: .speed)
        try c.encode(stroke.tipOffset, forKey: .tipOffset)
        try c.encode(meterStep, forKey: .meterStep)
        try c.encodeIfPresent(cuePlacement, forKey: .cuePlacement)
        try c.encodeIfPresent(ghost, forKey: .ghost)
    }
}
