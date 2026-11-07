import Geometry

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct Stroke: Hashable, Sendable {
    public let direction: Vec2
    /// Cue-ball launch speed in metres per second.
    public let speed: Double
    /// Normalized cue-tip offset: x is side, y is top/draw.
    public let tipOffset: Vec2

    public init(direction: Vec2, speed: Double, tipOffset: Vec2 = .zero) {
        precondition(direction.length > 0 && direction.length.isFinite)
        precondition(speed >= 0 && speed.isFinite)
        precondition(tipOffset.length <= 0.5 && tipOffset.x.isFinite && tipOffset.y.isFinite)
        self.direction = direction.normalized
        self.speed = speed
        self.tipOffset = tipOffset
    }
}

/// pooltool 0.6.0 BallParams defaults and default cue specifications.
public struct PhysicsParams: Hashable, Codable, Sendable {
    public let ballRadius: Double
    public let ballMass: Double
    public let slidingFriction: Double
    public let rollingFriction: Double
    /// pooltool's `u_sp_proportionality`; the dimensional coefficient is R × this value.
    public let spinningFrictionProportionality: Double
    public let ballBallFrictionA: Double
    public let ballBallFrictionB: Double
    public let ballBallFrictionC: Double
    public let ballBallRestitution: Double
    public let cushionRestitution: Double
    public let cushionFriction: Double
    public let cushionHeight: Double
    public let cushionWidth: Double
    public let cornerPocketDepth: Double
    public let cornerPocketRadius: Double
    public let cornerPocketAngle: Double
    public let cornerJawRadius: Double
    public let sidePocketDepth: Double
    public let sidePocketRadius: Double
    public let sidePocketAngle: Double
    public let sideJawRadius: Double
    public let gravity: Double
    public let cueMass: Double
    public let cueEndMass: Double
    public let englishThrottle: Double
    public let squirtThrottle: Double

    public static let standard = PhysicsParams()
    public var spinningFriction: Double { ballRadius * spinningFrictionProportionality }

    public init(
        ballRadius: Double = TableSpec.ballRadius,
        ballMass: Double = 0.170097,
        slidingFriction: Double = 0.2,
        rollingFriction: Double = 0.01,
        spinningFrictionProportionality: Double = 4.0 / 9.0,
        ballBallFrictionA: Double = 0.009951,
        ballBallFrictionB: Double = 0.108,
        ballBallFrictionC: Double = 1.088,
        ballBallRestitution: Double = 0.95,
        cushionRestitution: Double = 0.85,
        cushionFriction: Double = 0.2,
        cushionHeight: Double = 0.036576,
        cushionWidth: Double = 0.0508,
        cornerPocketDepth: Double = 0.0417,
        cornerPocketRadius: Double = 0.062,
        cornerPocketAngle: Double = 5.3 * Double.pi / 180,
        cornerJawRadius: Double = 0.02095,
        sidePocketDepth: Double = 0.0685,
        sidePocketRadius: Double = 0.0645,
        sidePocketAngle: Double = 7.14 * Double.pi / 180,
        sideJawRadius: Double = 0.00795,
        gravity: Double = 9.81,
        cueMass: Double = 0.567,
        cueEndMass: Double = 0.170097 / 30,
        englishThrottle: Double = 1,
        squirtThrottle: Double = 1
    ) {
        self.ballRadius = ballRadius
        self.ballMass = ballMass
        self.slidingFriction = slidingFriction
        self.rollingFriction = rollingFriction
        self.spinningFrictionProportionality = spinningFrictionProportionality
        self.ballBallFrictionA = ballBallFrictionA
        self.ballBallFrictionB = ballBallFrictionB
        self.ballBallFrictionC = ballBallFrictionC
        self.ballBallRestitution = ballBallRestitution
        self.cushionRestitution = cushionRestitution
        self.cushionFriction = cushionFriction
        self.cushionHeight = cushionHeight
        self.cushionWidth = cushionWidth
        self.cornerPocketDepth = cornerPocketDepth
        self.cornerPocketRadius = cornerPocketRadius
        self.cornerPocketAngle = cornerPocketAngle
        self.cornerJawRadius = cornerJawRadius
        self.sidePocketDepth = sidePocketDepth
        self.sidePocketRadius = sidePocketRadius
        self.sidePocketAngle = sidePocketAngle
        self.sideJawRadius = sideJawRadius
        self.gravity = gravity
        self.cueMass = cueMass
        self.cueEndMass = cueEndMass
        self.englishThrottle = englishThrottle
        self.squirtThrottle = squirtThrottle
    }
}

public enum Rail: String, Codable, Hashable, Sendable {
    case foot, head, left, right, cornerJaw, sideJaw
}

public enum PhysicsEventKind: String, Codable, Hashable, Sendable {
    case ballBall, cushion, pocket, slideToRoll, spinOff, rest
}

public enum PhysicsEvent: Hashable, Codable, Sendable {
    case ballBall(BallID, BallID)
    case cushion(BallID, Rail)
    case pocket(BallID, Pocket)
    case slideToRoll(BallID)
    case spinOff(BallID)
    case rest(BallID)

    public var kind: PhysicsEventKind {
        switch self {
        case .ballBall: .ballBall
        case .cushion: .cushion
        case .pocket: .pocket
        case .slideToRoll: .slideToRoll
        case .spinOff: .spinOff
        case .rest: .rest
        }
    }

    public var ballIDs: [BallID] {
        switch self {
        case let .ballBall(a, b): [a, b]
        case let .cushion(ball, _), let .pocket(ball, _), let .slideToRoll(ball), let .spinOff(ball), let .rest(ball): [ball]
        }
    }

    fileprivate var priority: Int {
        switch self {
        case .pocket, .slideToRoll, .rest, .spinOff: 2
        case .ballBall, .cushion: 3
        }
    }
}

public struct TimedEvent: Hashable, Codable, Sendable {
    public let time: Double
    public let event: PhysicsEvent

    public init(time: Double, event: PhysicsEvent) {
        self.time = time
        self.event = event
    }
}

private struct Snapshot: Hashable, Sendable {
    let time: Double
    let state: TableState
}

private struct CushionSegment {
    let start: Vec2
    let end: Vec2
    let rail: Rail
}

private struct CircularCushion {
    let center: Vec2
    let radius: Double
    let rail: Rail
}

private struct PocketTarget {
    let pocket: Pocket
    let center: Vec2
    let radius: Double
}

private struct TableGeometry {
    let linearCushions: [CushionSegment]
    let circularCushions: [CircularCushion]
    let pockets: [PocketTarget]
}

public struct ShotTrace: Hashable, Sendable {
    public let events: [TimedEvent]
    public let final: TableState
    public let initial: TableState
    public let duration: Double
    private let snapshots: [Snapshot]
    private let params: PhysicsParams

    fileprivate init(events: [TimedEvent], final: TableState, initial: TableState,
                     duration: Double, snapshots: [Snapshot], params: PhysicsParams) {
        self.events = events
        self.final = final
        self.initial = initial
        self.duration = duration
        self.snapshots = snapshots
        self.params = params
    }

    public func state(at requestedTime: Double) -> TableState {
        let time = requestedTime.isNaN ? 0 : min(duration, max(0, requestedTime))
        var snapshot = snapshots[0]
        for item in snapshots where item.time <= time { snapshot = item }
        guard time > snapshot.time else { return snapshot.state }
        var result = snapshot.state
        for id in result.balls.keys.sorted() {
            guard let ball = result.balls[id] else { continue }
            result.balls[id] = advance(ball, by: time - snapshot.time, params: params)
        }
        return result
    }

    public func path(of id: BallID, sampleDT: Double) -> [Vec2] {
        guard let start = initial.balls[id]?.position else { return [] }
        guard sampleDT > 0 && sampleDT.isFinite else { return [start] }
        var result = [start]
        var time = sampleDT
        while time < duration {
            if let position = state(at: time).balls[id]?.position { result.append(position) }
            time += sampleDT
        }
        if duration > 0, let end = final.balls[id]?.position { result.append(end) }
        return result
    }
}

public struct Simulator: Sendable {
    public let params: PhysicsParams

    public init(params: PhysicsParams = .standard) { self.params = params }

    public func simulate(_ state: TableState, stroke: Stroke) -> ShotTrace {
        var launched = state
        guard var cue = launched.balls[.cue] else {
            return ShotTrace(events: [], final: state, initial: state, duration: 0,
                             snapshots: [Snapshot(time: 0, state: state)], params: params)
        }
        cue = strike(cue, stroke: stroke, params: params)
        launched.balls[.cue] = cue

        let geometry = tableGeometry(launched.spec, params: params)
        var current = launched
        var time = 0.0
        var events: [TimedEvent] = []
        var snapshots = [Snapshot(time: 0, state: launched)]

        // ponytail: all-pairs quartic search is O(n²); use a spatial broadphase if simulations exceed 16 balls.
        for _ in 0..<4096 {
            guard let candidate = nextEvent(in: current, geometry: geometry) else { break }
            let delta = max(0, candidate.time)
            for id in current.balls.keys.sorted() {
                guard let ball = current.balls[id] else { continue }
                current.balls[id] = advance(ball, by: delta, params: params)
            }
            time += delta
            apply(candidate, to: &current, geometry: geometry, params: params)
            events.append(TimedEvent(time: time, event: candidate.event))
            snapshots.append(Snapshot(time: time, state: current))
        }

        return ShotTrace(events: events, final: current, initial: launched, duration: time,
                         snapshots: snapshots, params: params)
    }

    private func nextEvent(in state: TableState, geometry: TableGeometry) -> Candidate? {
        let ids = state.balls.keys.sorted()
        var best: Candidate?
        var transitionLimit = Double.infinity

        for id in ids {
            guard let ball = state.balls[id], let transition = transition(for: ball, id: id, params: params) else { continue }
            transitionLimit = min(transitionLimit, transition.time)
            best = choose(best, transition)
        }

        let horizon = transitionLimit.isFinite ? transitionLimit : 30
        guard horizon > 0 else { return best }
        for i in ids.indices {
            let firstID = ids[i]
            guard let first = state.balls[firstID], first.motion != .pocketed else { continue }
            for secondID in ids.dropFirst(i + 1) {
                guard let second = state.balls[secondID], second.motion != .pocketed else { continue }
                if let dt = ballBallTime(first, second, horizon: horizon, params: params) {
                    best = choose(best, Candidate(time: dt, event: .ballBall(firstID, secondID)))
                }
            }
            for segment in geometry.linearCushions {
                if let hit = linearCushionTime(first, segment: segment, horizon: horizon, spec: state.spec, params: params) {
                    best = choose(best, Candidate(time: hit.time, event: .cushion(firstID, segment.rail), cushionNormal: hit.outward))
                }
            }
            for segment in geometry.circularCushions {
                if let hit = circularCushionTime(first, segment: segment, horizon: horizon, params: params) {
                    best = choose(best, Candidate(time: hit.time, event: .cushion(firstID, segment.rail), cushionNormal: hit.outward))
                }
            }
            for pocket in geometry.pockets {
                if let dt = pocketTime(first, pocket: pocket, horizon: horizon, params: params) {
                    best = choose(best, Candidate(time: dt, event: .pocket(firstID, pocket.pocket)))
                }
            }
        }
        return best
    }

    private func apply(_ candidate: Candidate, to state: inout TableState, geometry: TableGeometry, params: PhysicsParams) {
        switch candidate.event {
        case let .ballBall(firstID, secondID):
            guard let first = state.balls[firstID], let second = state.balls[secondID] else { return }
            let updated = collide(first, second, params: params)
            state.balls[firstID] = updated.0
            state.balls[secondID] = updated.1
        case let .cushion(id, rail):
            guard var ball = state.balls[id] else { return }
            ball = cushion(ball, outward: candidate.cushionNormal ?? outwardNormal(rail), params: params)
            state.balls[id] = ball
        case let .pocket(id, pocket):
            guard var ball = state.balls[id] else { return }
            ball.position = geometry.pockets.first(where: { $0.pocket == pocket })?.center ?? state.spec.pocketCenter(pocket)
            ball.velocity = .zero
            ball.angularVelocity = .zero
            ball.motion = .pocketed
            state.balls[id] = ball
        case let .slideToRoll(id):
            guard var ball = state.balls[id] else { return }
            let speed = ball.velocity.length
            ball.angularVelocity.x = speed > 0 ? -ball.velocity.y / params.ballRadius : 0
            ball.angularVelocity.y = speed > 0 ? ball.velocity.x / params.ballRadius : 0
            ball.motion = speed > 1e-10 ? .rolling : (abs(ball.angularVelocity.z) > 1e-10 ? .spinning : .stationary)
            state.balls[id] = ball
        case let .rest(id):
            guard var ball = state.balls[id] else { return }
            ball.velocity = .zero
            ball.angularVelocity.x = 0
            ball.angularVelocity.y = 0
            ball.motion = abs(ball.angularVelocity.z) > 1e-10 ? .spinning : .stationary
            state.balls[id] = ball
        case let .spinOff(id):
            guard var ball = state.balls[id] else { return }
            ball.angularVelocity.z = 0
            ball.motion = .stationary
            state.balls[id] = ball
        }
    }
}

public enum AimGeometry {
    public static func ghostBall(object: Vec2, pocket: Vec2, ballRadius: Double = TableSpec.ballRadius) -> Vec2 {
        object - (pocket - object).normalized * (2 * ballRadius)
    }

    public static func tangentDirection(contactNormal: Vec2) -> Vec2 {
        contactNormal.normalized.perpendicular
    }

    /// Rolling cue-ball estimate for the 30-degree rule; signed cut angle is in radians.
    public static func thirtyDegreeRuleDirection(shotDirection: Vec2, cutAngle: Double) -> Vec2 {
        let turn = cutAngle > 0 ? -Double.pi / 6 : (cutAngle < 0 ? Double.pi / 6 : 0)
        return shotDirection.normalized.rotated(by: turn)
    }
}

private struct Candidate {
    let time: Double
    let event: PhysicsEvent
    let cushionNormal: Vec2?

    init(time: Double, event: PhysicsEvent, cushionNormal: Vec2? = nil) {
        self.time = time
        self.event = event
        self.cushionNormal = cushionNormal
    }
}

private struct CushionHit {
    let time: Double
    let outward: Vec2
}

private func choose(_ current: Candidate?, _ next: Candidate) -> Candidate {
    guard let current else { return next }
    if next.time < current.time - 1e-11 { return next }
    if abs(next.time - current.time) <= 1e-11 && next.event.priority < current.event.priority { return next }
    return current
}

private func strike(_ ball: BallState, stroke: Stroke, params p: PhysicsParams) -> BallState {
    // pooltool 0.6 InstantaneousPoint; cue impulse and squirt derive from Dr. Dave TP A-30/A-31.
    let a = stroke.tipOffset.x
    let b = stroke.tipOffset.y
    let direction = stroke.direction.normalized
    let massRatio = p.ballMass / p.cueEndMass
    let squash = 1 - a * a
    let squirt = -p.squirtThrottle * atan2(2.5 * a * sqrt(max(0, squash)), 1 + massRatio + 2.5 * squash)
    let launchedDirection = direction.rotated(by: squirt)
    let speed = stroke.speed
    var result = ball
    result.velocity = launchedDirection * speed
    result.angularVelocity = SIMD3Codable(
        -2.5 * b * speed * direction.y * p.englishThrottle / p.ballRadius,
        2.5 * b * speed * direction.x * p.englishThrottle / p.ballRadius,
        -2.5 * a * speed * p.englishThrottle / p.ballRadius
    )
    result.motion = .sliding
    return result
}

private func transition(for ball: BallState, id: BallID, params p: PhysicsParams) -> Candidate? {
    let time: Double
    let event: PhysicsEvent
    switch ball.motion {
    case .sliding:
        let slip = Vec2(ball.velocity.x - p.ballRadius * ball.angularVelocity.y,
                        ball.velocity.y + p.ballRadius * ball.angularVelocity.x)
        guard p.slidingFriction > 0 else { return nil }
        time = 2 * slip.length / (7 * p.slidingFriction * p.gravity)
        event = .slideToRoll(id)
    case .rolling:
        guard p.rollingFriction > 0 else { return nil }
        time = ball.velocity.length / (p.rollingFriction * p.gravity)
        event = .rest(id)
    case .spinning:
        guard p.spinningFriction > 0 else { return nil }
        let alpha = 5 * p.spinningFriction * p.gravity / (2 * p.ballRadius)
        time = abs(ball.angularVelocity.z) / alpha
        event = .spinOff(id)
    case .stationary, .pocketed:
        return nil
    }
    return Candidate(time: max(0, time), event: event)
}

private func acceleration(of ball: BallState, params p: PhysicsParams) -> Vec2 {
    switch ball.motion {
    case .sliding:
        let slip = Vec2(ball.velocity.x - p.ballRadius * ball.angularVelocity.y,
                        ball.velocity.y + p.ballRadius * ball.angularVelocity.x)
        return slip.normalized * (-p.slidingFriction * p.gravity)
    case .rolling:
        return ball.velocity.normalized * (-p.rollingFriction * p.gravity)
    case .stationary, .spinning, .pocketed:
        return .zero
    }
}

private func advance(_ ball: BallState, by dt: Double, params p: PhysicsParams) -> BallState {
    guard dt > 0 else { return ball }
    var result = ball
    switch ball.motion {
    case .sliding:
        // pooltool's constant-friction sliding equations; zero contact slip gives the 5/7 speed rule.
        let slip = Vec2(ball.velocity.x - p.ballRadius * ball.angularVelocity.y,
                        ball.velocity.y + p.ballRadius * ball.angularVelocity.x).normalized
        let friction = p.slidingFriction * p.gravity
        result.position += ball.velocity * dt - slip * (0.5 * friction * dt * dt)
        result.velocity -= slip * (friction * dt)
        let angularDelta = 2.5 * friction * dt / p.ballRadius
        result.angularVelocity.x -= angularDelta * slip.y
        result.angularVelocity.y += angularDelta * slip.x
        result.angularVelocity.z = decaySpin(ball.angularVelocity.z, by: dt, params: p)
    case .rolling:
        let direction = ball.velocity.normalized
        let friction = p.rollingFriction * p.gravity
        result.position += ball.velocity * dt - direction * (0.5 * friction * dt * dt)
        result.velocity -= direction * (friction * dt)
        result.angularVelocity.x = -result.velocity.y / p.ballRadius
        result.angularVelocity.y = result.velocity.x / p.ballRadius
        result.angularVelocity.z = decaySpin(ball.angularVelocity.z, by: dt, params: p)
    case .spinning:
        result.angularVelocity.z = decaySpin(ball.angularVelocity.z, by: dt, params: p)
    case .stationary, .pocketed:
        break
    }
    return result
}

private func decaySpin(_ spin: Double, by dt: Double, params p: PhysicsParams) -> Double {
    let amount = 5 * p.spinningFriction * p.gravity / (2 * p.ballRadius) * dt
    return abs(spin) <= amount ? 0 : spin - (spin > 0 ? amount : -amount)
}

private func ballBallTime(_ first: BallState, _ second: BallState, horizon: Double, params p: PhysicsParams) -> Double? {
    let relativePosition = second.position - first.position
    let relativeVelocity = second.velocity - first.velocity
    let relativeAcceleration = acceleration(of: second, params: p) - acceleration(of: first, params: p)
    let halfAcceleration = relativeAcceleration * 0.5
    let diameter = 2 * p.ballRadius
    let coefficients = [
        relativePosition.lengthSquared - diameter * diameter,
        2 * relativePosition.dot(relativeVelocity),
        relativeVelocity.lengthSquared + relativePosition.dot(relativeAcceleration),
        2 * relativeVelocity.dot(halfAcceleration),
        halfAcceleration.lengthSquared,
    ]
    if coefficients[0] <= 1e-12 {
        return coefficients[1] < -1e-10 ? 0 : nil
    }
    return polynomialRoots(coefficients, through: horizon).first { root in
        root > 1e-10 && polynomialValue(derivative(of: coefficients), at: root) <= 1e-8
    }
}

/// Isolates real roots by recursively partitioning the polynomial at its derivative roots.
/// Ball-ball distance squared is quartic because each ball has constant acceleration between events.
private func polynomialRoots(_ coefficients: [Double], through end: Double) -> [Double] {
    var c = coefficients
    while c.count > 1 && abs(c.last!) < 1e-15 { c.removeLast() }
    if c.count == 2 {
        let root = -c[0] / c[1]
        return root >= 0 && root <= end ? [root] : []
    }
    guard c.count > 2 else { return [] }
    let critical = polynomialRoots(derivative(of: c), through: end)
    var points = [0.0] + critical + [end]
    points.sort()
    var roots: [Double] = []
    let scale = max(1, c.enumerated().reduce(0.0) { $0 + abs($1.element) * pow(end, Double($1.offset)) })
    let tolerance = scale * 1e-12
    for point in points where abs(polynomialValue(c, at: point)) <= tolerance {
        roots.append(point)
    }
    for index in 0..<(points.count - 1) {
        var low = points[index]
        var high = points[index + 1]
        var fLow = polynomialValue(c, at: low)
        let fHigh = polynomialValue(c, at: high)
        guard fLow * fHigh < 0 else { continue }
        for _ in 0..<64 {
            let middle = (low + high) / 2
            let fMiddle = polynomialValue(c, at: middle)
            if fLow * fMiddle <= 0 { high = middle }
            else { low = middle; fLow = fMiddle }
        }
        roots.append((low + high) / 2)
    }
    roots.sort()
    var unique: [Double] = []
    for root in roots where unique.last.map({ abs($0 - root) > 1e-8 }) ?? true { unique.append(root) }
    return unique
}

private func derivative(of coefficients: [Double]) -> [Double] {
    Array(coefficients.enumerated().dropFirst().map { Double($0.offset) * $0.element })
}

private func polynomialValue(_ coefficients: [Double], at x: Double) -> Double {
    coefficients.reversed().reduce(0) { $0 * x + $1 }
}

private func tableGeometry(_ spec: TableSpec, params p: PhysicsParams) -> TableGeometry {
    let length = spec.length
    let width = spec.width
    let cornerWidth = spec.cornerMouth
    let sideWidth = spec.sideMouth
    let cornerAngle = p.cornerPocketAngle + Double.pi / 4
    let sideAngle = p.sidePocketAngle
    let cornerJawOffset = p.cornerJawRadius / tan((Double.pi / 2 + cornerAngle) / 2)
    let sideJawOffset = p.sideJawRadius / tan((Double.pi / 2 + sideAngle) / 2)
    let cornerDiagonal = cornerWidth * cos(Double.pi / 4)
    let cushionWidth = p.cushionWidth

    // pooltool's pocket-table convention is width-first with +y toward the foot rail;
    // this proper rotation maps its (x, y) into CueCoach's (lengthwise x, widthwise y).
    func point(_ poolX: Double, _ poolY: Double) -> Vec2 { Vec2(length - poolY, poolX) }
    func segment(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ rail: Rail) -> CushionSegment {
        CushionSegment(start: point(x1, y1), end: point(x2, y2), rail: rail)
    }
    let linear = [
        segment(0, cornerDiagonal + cornerJawOffset, 0, (length - sideWidth) / 2 - sideJawOffset, .left),
        segment(0, (length + sideWidth) / 2 + sideJawOffset, 0, -cornerDiagonal + length - cornerJawOffset, .left),
        segment(width, cornerDiagonal + cornerJawOffset, width, (length - sideWidth) / 2 - sideJawOffset, .right),
        segment(width, (length + sideWidth) / 2 + sideJawOffset, width, -cornerDiagonal + length - cornerJawOffset, .right),
        segment(cornerDiagonal + cornerJawOffset, 0, -cornerDiagonal + width - cornerJawOffset, 0, .head),
        segment(cornerDiagonal + cornerJawOffset, length, -cornerDiagonal + width - cornerJawOffset, length, .foot),
        segment(-cushionWidth, (length + sideWidth) / 2 - cushionWidth * sin(sideAngle),
                -sideJawOffset * cos(sideAngle), (length + sideWidth) / 2 - sideJawOffset * sin(sideAngle), .sideJaw),
        segment(-cushionWidth, (length - sideWidth) / 2 + cushionWidth * sin(sideAngle),
                -sideJawOffset * cos(sideAngle), (length - sideWidth) / 2 + sideJawOffset * sin(sideAngle), .sideJaw),
        segment(width + cushionWidth, (length + sideWidth) / 2 - cushionWidth * sin(sideAngle),
                width + sideJawOffset * cos(sideAngle), (length + sideWidth) / 2 - sideJawOffset * sin(sideAngle), .sideJaw),
        segment(width + cushionWidth, (length - sideWidth) / 2 + cushionWidth * sin(sideAngle),
                width + sideJawOffset * cos(sideAngle), (length - sideWidth) / 2 + sideJawOffset * sin(sideAngle), .sideJaw),
        segment(cornerDiagonal - cushionWidth * tan(cornerAngle), -cushionWidth,
                cornerDiagonal - cornerJawOffset * sin(cornerAngle), -cornerJawOffset * cos(cornerAngle), .cornerJaw),
        segment(-cushionWidth, cornerDiagonal - cushionWidth * tan(cornerAngle),
                -cornerJawOffset * cos(cornerAngle), cornerDiagonal - cornerJawOffset * sin(cornerAngle), .cornerJaw),
        segment(cornerDiagonal - cushionWidth * tan(cornerAngle), cushionWidth + length,
                cornerDiagonal - cornerJawOffset * sin(cornerAngle), length + cornerJawOffset * cos(cornerAngle), .cornerJaw),
        segment(-cushionWidth, -cornerDiagonal + cushionWidth * tan(cornerAngle) + length,
                -cornerJawOffset * cos(cornerAngle), -cornerDiagonal + length + cornerJawOffset * sin(cornerAngle), .cornerJaw),
        segment(width + cushionWidth, -cornerDiagonal + cushionWidth * tan(cornerAngle) + length,
                width + cornerJawOffset * cos(cornerAngle), -cornerDiagonal + length + cornerJawOffset * sin(cornerAngle), .cornerJaw),
        segment(-cornerDiagonal + cushionWidth * tan(cornerAngle) + width, cushionWidth + length,
                -cornerDiagonal + width + cornerJawOffset * sin(cornerAngle), length + cornerJawOffset * cos(cornerAngle), .cornerJaw),
        segment(width + cushionWidth, cornerDiagonal - cushionWidth * tan(cornerAngle),
                width + cornerJawOffset * cos(cornerAngle), cornerDiagonal - cornerJawOffset * sin(cornerAngle), .cornerJaw),
        segment(-cornerDiagonal + cushionWidth * tan(cornerAngle) + width, -cushionWidth,
                -cornerDiagonal + width + cornerJawOffset * sin(cornerAngle), -cornerJawOffset * cos(cornerAngle), .cornerJaw),
    ]

    func circle(_ x: Double, _ y: Double, _ radius: Double, _ rail: Rail) -> CircularCushion {
        CircularCushion(center: point(x, y), radius: radius, rail: rail)
    }
    let circles = [
        circle(cornerDiagonal + cornerJawOffset, -p.cornerJawRadius, p.cornerJawRadius, .cornerJaw),
        circle(-p.cornerJawRadius, cornerDiagonal + cornerJawOffset, p.cornerJawRadius, .cornerJaw),
        circle(-p.sideJawRadius, length / 2 - sideWidth / 2 - sideJawOffset, p.sideJawRadius, .sideJaw),
        circle(-p.sideJawRadius, length / 2 + sideWidth / 2 + sideJawOffset, p.sideJawRadius, .sideJaw),
        circle(-p.cornerJawRadius, length - (cornerDiagonal + cornerJawOffset), p.cornerJawRadius, .cornerJaw),
        circle(cornerDiagonal + cornerJawOffset, length + p.cornerJawRadius, p.cornerJawRadius, .cornerJaw),
        circle(width - cornerDiagonal - cornerJawOffset, length + p.cornerJawRadius, p.cornerJawRadius, .cornerJaw),
        circle(width + p.cornerJawRadius, length - (cornerDiagonal + cornerJawOffset), p.cornerJawRadius, .cornerJaw),
        circle(width + p.sideJawRadius, length / 2 + sideWidth / 2 + sideJawOffset, p.sideJawRadius, .sideJaw),
        circle(width + p.sideJawRadius, length / 2 - sideWidth / 2 - sideJawOffset, p.sideJawRadius, .sideJaw),
        circle(width + p.cornerJawRadius, cornerDiagonal + cornerJawOffset, p.cornerJawRadius, .cornerJaw),
        circle(width - cornerDiagonal - cornerJawOffset, -p.cornerJawRadius, p.cornerJawRadius, .cornerJaw),
    ]

    let cornerDepth = p.cornerPocketDepth / sqrt(2)
    let pockets = [
        PocketTarget(pocket: .headLeft, center: point(-cornerDepth, -cornerDepth), radius: p.cornerPocketRadius),
        PocketTarget(pocket: .headRight, center: point(width + cornerDepth, -cornerDepth), radius: p.cornerPocketRadius),
        PocketTarget(pocket: .sideLeft, center: point(-p.sidePocketDepth, length / 2), radius: p.sidePocketRadius),
        PocketTarget(pocket: .sideRight, center: point(width + p.sidePocketDepth, length / 2), radius: p.sidePocketRadius),
        PocketTarget(pocket: .footLeft, center: point(-cornerDepth, length + cornerDepth), radius: p.cornerPocketRadius),
        PocketTarget(pocket: .footRight, center: point(width + cornerDepth, length + cornerDepth), radius: p.cornerPocketRadius),
    ]
    return TableGeometry(linearCushions: linear, circularCushions: circles, pockets: pockets)
}

private func linearCushionTime(_ ball: BallState, segment: CushionSegment, horizon: Double,
                               spec: TableSpec, params p: PhysicsParams) -> CushionHit? {
    guard ball.motion != .stationary && ball.motion != .spinning && ball.motion != .pocketed else { return nil }
    let direction = segment.end - segment.start
    let midpoint = (segment.start + segment.end) * 0.5
    var inward = direction.perpendicular.normalized
    if inward.dot(Vec2(spec.length / 2, spec.width / 2) - midpoint) < 0 { inward = -inward }
    let startDistance = (ball.position - segment.start).dot(inward) - p.ballRadius
    let acceleration = acceleration(of: ball, params: p)
    let coefficients = [startDistance, ball.velocity.dot(inward), 0.5 * acceleration.dot(inward)]
    let distancePerpendicular = polynomialRoots(coefficients, through: horizon)
    for time in distancePerpendicular where time > 1e-10 && polynomialValue(derivative(of: coefficients), at: time) < -1e-10 {
        let center = position(ball, after: time, params: p)
        let contact = center - inward * p.ballRadius
        let progress = (contact - segment.start).dot(direction) / direction.lengthSquared
        if progress >= -1e-9 && progress <= 1 + 1e-9 {
            return CushionHit(time: time, outward: -inward)
        }
    }
    return nil
}

private func circularCushionTime(_ ball: BallState, segment: CircularCushion, horizon: Double,
                                 params p: PhysicsParams) -> CushionHit? {
    guard ball.motion != .stationary && ball.motion != .spinning && ball.motion != .pocketed else { return nil }
    let r = ball.position - segment.center
    let a = acceleration(of: ball, params: p)
    let target = p.ballRadius + segment.radius
    let coefficients = [
        r.lengthSquared - target * target,
        2 * r.dot(ball.velocity),
        ball.velocity.lengthSquared + r.dot(a),
        ball.velocity.dot(a),
        0.25 * a.lengthSquared,
    ]
    let root = polynomialRoots(coefficients, through: horizon).first {
        $0 > 1e-10 && polynomialValue(derivative(of: coefficients), at: $0) < -1e-10
    }
    guard let root else { return nil }
    return CushionHit(time: root, outward: -(position(ball, after: root, params: p) - segment.center).normalized)
}

private func pocketTime(_ ball: BallState, pocket: PocketTarget, horizon: Double, params p: PhysicsParams) -> Double? {
    guard ball.motion != .stationary && ball.motion != .spinning && ball.motion != .pocketed else { return nil }
    let r = ball.position - pocket.center
    let a = acceleration(of: ball, params: p)
    let coefficients = [
        r.lengthSquared - pocket.radius * pocket.radius,
        2 * r.dot(ball.velocity),
        ball.velocity.lengthSquared + r.dot(a),
        ball.velocity.dot(a),
        0.25 * a.lengthSquared,
    ]
    return polynomialRoots(coefficients, through: horizon).first {
        $0 > 1e-10 && polynomialValue(derivative(of: coefficients), at: $0) < -1e-10
    }
}

private func position(_ ball: BallState, after dt: Double, params p: PhysicsParams) -> Vec2 {
    let a = acceleration(of: ball, params: p)
    return ball.position + ball.velocity * dt + a * (0.5 * dt * dt)
}

private func outwardNormal(_ rail: Rail) -> Vec2 {
    switch rail {
    case .foot: Vec2(-1, 0)
    case .head: Vec2(1, 0)
    case .left: Vec2(0, -1)
    case .right: Vec2(0, 1)
    case .cornerJaw, .sideJaw: .zero
    }
}

private func collide(_ first: BallState, _ second: BallState, params p: PhysicsParams) -> (BallState, BallState) {
    // pooltool FrictionalInelastic with Alciatore friction; related derivations: Dr. Dave TP A-5/A-6/A-14.
    let normal = (second.position - first.position).normalized
    let angle = atan2(normal.y, normal.x)
    let v1 = rotate3(SIMD3(first.velocity.x, first.velocity.y, 0), by: -angle)
    let v2 = rotate3(SIMD3(second.velocity.x, second.velocity.y, 0), by: -angle)
    let w1 = rotate3(SIMD3(first.angularVelocity.x, first.angularVelocity.y, first.angularVelocity.z), by: -angle)
    let w2 = rotate3(SIMD3(second.angularVelocity.x, second.angularVelocity.y, second.angularVelocity.z), by: -angle)
    let v1n = v1.x
    let v2n = v2.x
    let v1Normal = 0.5 * ((1 - p.ballBallRestitution) * v1n + (1 + p.ballBallRestitution) * v2n)
    let v2Normal = 0.5 * ((1 + p.ballBallRestitution) * v1n + (1 - p.ballBallRestitution) * v2n)
    let normalImpulse = abs(v2Normal - v1Normal)
    let normalAxis = SIMD3<Double>(1, 0, 0)
    let t1 = SIMD3<Double>(0, v1.y, 0)
    let t2 = SIMD3<Double>(0, v2.y, 0)
    let spin1 = SIMD3<Double>(0, w1.y, w1.z)
    let spin2 = SIMD3<Double>(0, w2.y, w2.z)
    let contact1 = t1 + cross3(spin1, SIMD3(p.ballRadius, 0, 0))
    let contact2 = t2 + cross3(spin2, SIMD3(-p.ballRadius, 0, 0))
    let slip = contact1 - contact2
    let speed = length3(slip)
    var finalV1 = SIMD3<Double>(0, 0, 0)
    var finalV2 = SIMD3<Double>(0, 0, 0)
    var finalW1 = spin1
    var finalW2 = spin2

    if speed > 1e-12 && normalImpulse > 0 {
        let friction = p.ballBallFrictionA + p.ballBallFrictionB * exp(-p.ballBallFrictionC * speed)
        let tangentImpulse = slip * (-friction * normalImpulse / speed)
        let deltaSpin = cross3(normalAxis, tangentImpulse) * (2.5 / p.ballRadius)
        finalV1 = t1 + tangentImpulse
        finalV2 = t2 - tangentImpulse
        finalW1 = spin1 + deltaSpin
        finalW2 = spin2 + deltaSpin

        let afterSlip = (finalV1 + cross3(finalW1, SIMD3(p.ballRadius, 0, 0))) -
                        (finalV2 + cross3(finalW2, SIMD3(-p.ballRadius, 0, 0)))
        if dot3(slip, afterSlip) <= 0 {
            // pooltool's no-slip branch resolves from the original tangential state, replacing the trial impulse.
            let deltaV = (t1 - t2 + cross3(spin1 + spin2, normalAxis) * p.ballRadius) * (-1.0 / 7)
            let deltaW = (cross3(normalAxis, t1 - t2) / p.ballRadius + spin1 + spin2) * (-5.0 / 14)
            finalV1 = t1 + deltaV
            finalV2 = t2 - deltaV
            finalW1 = spin1 + deltaW
            finalW2 = spin2 + deltaW
        }
    }

    finalV1.x = v1Normal
    finalV2.x = v2Normal
    finalW1.x = w1.x
    finalW2.x = w2.x
    let outputV1 = rotate3(finalV1, by: angle)
    let outputV2 = rotate3(finalV2, by: angle)
    let outputW1 = rotate3(finalW1, by: angle)
    let outputW2 = rotate3(finalW2, by: angle)
    var a = first
    var b = second
    a.velocity = Vec2(outputV1.x, outputV1.y)
    b.velocity = Vec2(outputV2.x, outputV2.y)
    a.angularVelocity = SIMD3Codable(outputW1.x, outputW1.y, outputW1.z)
    b.angularVelocity = SIMD3Codable(outputW2.x, outputW2.y, outputW2.z)
    a.motion = .sliding
    b.motion = .sliding
    return (a, b)
}

private func cushion(_ ball: BallState, outward: Vec2, params p: PhysicsParams) -> BallState {
    // Port of pooltool's Han 2005 resolver. pooltool 0.6 uses constant e_c and f_c here.
    let angle = atan2(outward.y, outward.x)
    var v = rotate3(SIMD3(ball.velocity.x, ball.velocity.y, 0), by: -angle)
    var w = rotate3(SIMD3(ball.angularVelocity.x, ball.angularVelocity.y, ball.angularVelocity.z), by: -angle)
    let theta = asin(min(1, max(-1, p.cushionHeight / p.ballRadius - 1)))
    let sx = v.x * sin(theta) + p.ballRadius * w.y
    let sy = -v.y - p.ballRadius * w.z * cos(theta) + p.ballRadius * w.x * sin(theta)
    let c = -v.x * cos(theta)
    let normalImpulse = -(1 + p.cushionRestitution) * c * p.ballMass
    let slip = sqrt(sx * sx + sy * sy)
    let frictionImpulse: SIMD3<Double>
    if (2 * p.ballMass / 7) * slip <= p.cushionFriction * normalImpulse || slip == 0 {
        frictionImpulse = SIMD3(sx * (2 * p.ballMass / 7), sy * (2 * p.ballMass / 7), 0)
    } else {
        frictionImpulse = SIMD3(sx * p.cushionFriction * normalImpulse / slip,
                                sy * p.cushionFriction * normalImpulse / slip, 0)
    }
    let px = -frictionImpulse.x * sin(theta) - normalImpulse * cos(theta)
    let py = frictionImpulse.y
    let pz = frictionImpulse.x * cos(theta) - normalImpulse * sin(theta)
    v.x += px / p.ballMass
    v.y += py / p.ballMass
    let inertia = 0.4 * p.ballMass * p.ballRadius * p.ballRadius
    w.x += -p.ballRadius / inertia * py * sin(theta)
    w.y += p.ballRadius / inertia * (px * sin(theta) - pz * cos(theta))
    w.z += p.ballRadius / inertia * py * cos(theta)
    v = rotate3(v, by: angle)
    w = rotate3(w, by: angle)
    var result = ball
    result.velocity = Vec2(v.x, v.y)
    result.angularVelocity = SIMD3Codable(w.x, w.y, w.z)
    result.motion = .sliding
    return result
}

private func rotate3(_ v: SIMD3<Double>, by angle: Double) -> SIMD3<Double> {
    let c = cos(angle)
    let s = sin(angle)
    return SIMD3(c * v.x - s * v.y, s * v.x + c * v.y, v.z)
}

private func cross3(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

private func dot3(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    a.x * b.x + a.y * b.y + a.z * b.z
}

private func length3(_ a: SIMD3<Double>) -> Double { sqrt(dot3(a, a)) }
