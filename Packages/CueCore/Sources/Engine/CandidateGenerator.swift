import Foundation
import Geometry
import Physics
import Rules

/// Per-class caps (engine.md §4.1).
public struct GeneratorCaps: Hashable, Codable, Sendable {
    public var maxTargetPockets = 24
    public var banks = 8
    public var kicks = 4
    public var kicksWhenSnookered = 8
    public var combos = 4
    public var safeties = 36
    public var pushOuts = 48
    public var ballInHandPlacements = 6
    public init() {}
}

/// Pure, synchronous candidate generator (engine.md §4). Geometry + `RulesEngine.legalTargets` only — no sims.
public struct CandidateGenerator: Sendable {
    /// Nominal cue-ball speed per power-meter step (engine.md §4.2; tunable defaults).
    public static let meterSpeeds: [Double] = [0.8, 1.3, 2.0, 3.0, 4.5]
    static let spins: [Vec2] = [.zero, Vec2(0, 0.3), Vec2(0, -0.3)]          // stun, follow, draw
    static let degree = Double.pi / 180

    public var rules: RulesEngine
    public var caps: GeneratorCaps
    /// Skill used to rank and cap (reference player).
    public var skill: SkillModel

    public init(rules: RulesEngine, caps: GeneratorCaps = GeneratorCaps(), skill: SkillModel = .reference) {
        self.rules = rules
        self.caps = caps
        self.skill = skill
    }

    /// Analytic description of one pot line, before stroke variants.
    struct Line {
        var kind: ShotKind
        var target: BallID
        var objectBall: BallID?
        var pocket: Pocket?
        var aimPoint: Vec2          // where the cue ball centre is sent (ghost, or mirrored ghost)
        var ghost: Vec2?
        var p: Double
        var minStep: Int
    }

    /// Object balls actually on the cloth (rules' `onTable` ∩ table state).
    static func liveObjects(_ s: TableState, _ g: GameState) -> [BallID: Vec2] {
        var out: [BallID: Vec2] = [:]
        for (id, b) in s.balls where !id.isCue && b.motion != .pocketed && g.onTable.contains(id) {
            out[id] = b.position
        }
        return out
    }

    static func step(for speed: Double) -> Int {
        meterSpeeds.firstIndex { $0 >= speed * 1.1 }.map { $0 + 1 } ?? 5
    }

    public func generate(_ s: TableState, _ g: GameState) -> [Candidate] {
        var out: [Candidate] = []
        func emit(_ kind: ShotKind, target: BallID?, ball: BallID?, pocket: Pocket?, dir: Vec2, step: Int,
                  tip: Vec2 = .zero, placement: Vec2?, ghost: Vec2? = nil) {
            guard dir.length > 1e-9 else { return }
            out.append(Candidate(id: UInt32(out.count), kind: kind, target: target, objectBall: ball, pocket: pocket,
                                 stroke: Stroke(direction: dir, speed: Self.meterSpeeds[step - 1], tipOffset: tip),
                                 meterStep: step, cuePlacement: placement, ghost: ghost))
        }
        let objects = Self.liveObjects(s, g)
        let spec = s.spec

        switch g.phase {
        case .awaitingOption, .over: return []
        case .breakShot:
            for (q, apex) in breakPlacements(objects, spec: spec) {
                for step in [4, 5] { emit(.breakShot, target: apex.0, ball: nil, pocket: nil, dir: apex.1 - q,
                                          step: step, placement: q) }
            }
            return out
        default: break
        }

        let legal = rules.legalTargets(g).filter { objects[$0] != nil }.sorted()
        let restrictKitchen = g.ballInHand == .behindHeadString
        // Straight-line shots at kitchen balls are WPA 3.11 fouls; kicks may still reach them by crossing the
        // head string first (rail point below it), and the simulation judges the result.
        let targets = restrictKitchen ? legal.filter { objects[$0]!.x >= spec.headStringX } : legal
        let kickTargets = restrictKitchen ? legal : targets

        // Cue position(s): the real cue ball, or ball-in-hand placements.
        var placements: [Vec2?] = []
        if g.ballInHand == .none, let cue = s.balls[.cue], cue.motion != .pocketed {
            placements = [nil]
        } else {
            placements = bihPlacements(objects, targets: targets, spec: spec, kitchen: restrictKitchen)
        }
        guard let firstPlacement = placements.first else { return [] }
        let defaultCue = firstPlacement ?? s.balls[.cue]!.position

        // Directs (per placement when in hand).
        var directLines: [(Line, Vec2?)] = []
        for placement in placements {
            let cue = placement ?? defaultCue
            for l in directs(cue: cue, objects: objects, targets: targets, spec: spec) { directLines.append((l, placement)) }
        }
        directLines.sort { $0.0.p > $1.0.p }
        var seenTP = Set<String>()
        var keptDirects: [(Line, Vec2?)] = []
        for (l, q) in directLines {
            let key = "\(l.objectBall!)-\(l.pocket!)"
            if !seenTP.contains(key) {
                guard seenTP.count < caps.maxTargetPockets else { continue }
                seenTP.insert(key)
            }
            keptDirects.append((l, q))
        }
        for (l, q) in keptDirects {
            for step in Set([l.minStep, min(5, l.minStep + 1)]).sorted() {
                for tip in Self.spins {
                    emit(.direct, target: l.target, ball: l.objectBall, pocket: l.pocket, dir: l.aimPoint - (q ?? defaultCue),
                         step: step, tip: tip, placement: q, ghost: l.ghost)
                }
            }
        }

        // Banks, kicks, combos from the default cue position (always generated, capped).
        let cue = defaultCue
        let placement = firstPlacement
        let snookered = !targets.contains { t in
            EngineGeometry.pathClear(from: cue, to: objects[t]!, blockers: Self.blockers(objects, except: [t]))
        }
        for l in banks(cue: cue, objects: objects, targets: targets, spec: spec).prefix(caps.banks) {
            emit(l.kind, target: l.target, ball: l.objectBall, pocket: l.pocket, dir: l.aimPoint - cue,
                 step: l.minStep, placement: placement, ghost: l.ghost)
        }
        for l in kicks(cue: cue, objects: objects, targets: kickTargets, spec: spec,
                       crossHeadString: restrictKitchen)
            .prefix(snookered ? caps.kicksWhenSnookered : caps.kicks) {
            emit(l.kind, target: l.target, ball: l.objectBall, pocket: l.pocket, dir: l.aimPoint - cue,
                 step: l.minStep, placement: placement, ghost: l.ghost)
        }
        let useful = usefulSecondBalls(g, objects: objects, legal: Set(legal))
        for l in combos(cue: cue, objects: objects, targets: targets, useful: useful, spec: spec).prefix(caps.combos) {
            emit(l.kind, target: l.target, ball: l.objectBall, pocket: l.pocket, dir: l.aimPoint - cue,
                 step: l.minStep, placement: placement, ghost: l.ghost)
        }

        // Safeties: always a coarse set (engine.md §4.4).
        var safeties = 0
        for (t, dir, step) in safetyStrokes(cue: cue, objects: objects, targets: targets, spec: spec) {
            guard safeties < caps.safeties else { break }
            emit(.safety, target: t, ball: nil, pocket: nil, dir: dir, step: step, placement: placement)
            safeties += 1
        }

        // Push-outs (WPA 5.4).
        if g.phase == .pushOutAvailable {
            var n = 0
            outer: for k in 0..<24 {
                for step in [1, 2] {
                    guard n < caps.pushOuts else { break outer }
                    let a = Double(k) * 15 * Self.degree
                    emit(.pushOut, target: nil, ball: nil, pocket: nil, dir: Vec2(cos(a), sin(a)), step: step,
                         placement: placement)
                    n += 1
                }
            }
        }
        return out
    }

    static func blockers(_ objects: [BallID: Vec2], except: Set<BallID>) -> [Vec2] {
        objects.keys.sorted().filter { !except.contains($0) }.map { objects[$0]! }
    }

    static func onCloth(_ q: Vec2, spec: TableSpec, margin: Double = 0.002) -> Bool {
        let r = EngineGeometry.R + margin
        return q.x > r && q.x < spec.length - r && q.y > r && q.y < spec.width - r
    }

    // MARK: Directs

    func directs(cue: Vec2, objects: [BallID: Vec2], targets: [BallID], spec: TableSpec) -> [Line] {
        var lines: [Line] = []
        for t in targets {
            let o = objects[t]!
            let others = Self.blockers(objects, except: [t])
            for p in Pocket.allCases {
                let pc = spec.pocketCenter(p)
                let ghost = AimGeometry.ghostBall(object: o, pocket: pc)
                guard Self.onCloth(ghost, spec: spec, margin: -0.004) else { continue }
                let cut = EngineGeometry.cutAngle(cue: cue, object: o, pocket: pc)
                guard cut < AnalyticP.maxCut else { continue }
                guard EngineGeometry.pathClear(from: cue, to: ghost, blockers: others),
                      EngineGeometry.pathClear(from: o, to: pc, blockers: others) else { continue }
                let pm = AnalyticP.direct(cue: cue, object: o, pocket: p, spec: spec, skill: skill)
                guard pm > 0.005 else { continue }
                let v = AnalyticP.requiredSpeed(cueTravel: cue.distance(to: ghost), obTravel: o.distance(to: pc), cut: cut)
                lines.append(Line(kind: .direct, target: t, objectBall: t, pocket: p, aimPoint: ghost, ghost: ghost,
                                  p: pm, minStep: Self.step(for: v)))
            }
        }
        return lines
    }

    // MARK: Banks (engine.md §4.1: mirror the pocket across the rail)

    func banks(cue: Vec2, objects: [BallID: Vec2], targets: [BallID], spec: TableSpec) -> [Line] {
        var lines: [Line] = []
        for t in targets {
            let o = objects[t]!
            let others = Self.blockers(objects, except: [t])
            for rail in EngineGeometry.railsAll {
                for p in Pocket.allCases where !EngineGeometry.rails(of: p).contains(rail) {
                    let pc = spec.pocketCenter(p)
                    let pm = EngineGeometry.mirror(pc, across: rail, spec: spec)
                    guard let bp = EngineGeometry.railPoint(from: o, toMirrored: pm, rail: rail, spec: spec) else { continue }
                    let ghost = AimGeometry.ghostBall(object: o, pocket: pm)
                    guard Self.onCloth(ghost, spec: spec, margin: -0.004),
                          EngineGeometry.pathClear(from: cue, to: ghost, blockers: others),
                          EngineGeometry.pathClear(from: o, to: bp, blockers: others),
                          EngineGeometry.pathClear(from: bp, to: pc, blockers: others) else { continue }
                    let pm2 = AnalyticP.bank(cue: cue, object: o, pocket: p, rail: rail, spec: spec, skill: skill)
                    guard pm2 > 0.02 else { continue }
                    let cut = EngineGeometry.angleBetween(ghost - cue, pm - o)
                    let v = AnalyticP.requiredSpeed(cueTravel: cue.distance(to: ghost), obTravel: o.distance(to: pm),
                                                    cut: cut, rails: 1)
                    lines.append(Line(kind: .bank(rail), target: t, objectBall: t, pocket: p, aimPoint: ghost,
                                      ghost: ghost, p: pm2, minStep: Self.step(for: v)))
                }
            }
        }
        return lines.sorted { $0.p > $1.p }
    }

    // MARK: Kicks (mirror the ghost / the ball across the rail)

    /// `crossHeadString`: ball in hand in the kitchen; a kick at a kitchen ball must bounce below the head string.
    func kicks(cue: Vec2, objects: [BallID: Vec2], targets: [BallID], spec: TableSpec,
               crossHeadString: Bool = false) -> [Line] {
        var pots: [Line] = [], hits: [Line] = []
        let line = spec.headStringX
        let all = Self.blockers(objects, except: [])
        for t in targets {
            let o = objects[t]!
            let others = Self.blockers(objects, except: [t])
            let mustCross = crossHeadString && o.x < line
            for rail in EngineGeometry.railsAll {
                // Kick to hit the ball (legal contact).
                let om = EngineGeometry.mirror(o, across: rail, spec: spec)
                if let rp = EngineGeometry.railPoint(from: cue, toMirrored: om, rail: rail, spec: spec),
                   !mustCross || rp.x > line,
                   EngineGeometry.pathClear(from: cue, to: rp, blockers: all),
                   EngineGeometry.pathClear(from: rp, to: o, blockers: others) {
                    let v = AnalyticP.requiredSpeed(cueTravel: cue.distance(to: om), obTravel: 0.3, cut: 0, rails: 1)
                    hits.append(Line(kind: .kick(rail), target: t, objectBall: nil, pocket: nil, aimPoint: om, ghost: nil,
                                     p: AnalyticP.kickHit(cue: cue, object: o, rail: rail, spec: spec, skill: skill),
                                     minStep: Self.step(for: v)))
                }
                // Kick to pot.
                for p in Pocket.allCases {
                    let pc = spec.pocketCenter(p)
                    let ghost = AimGeometry.ghostBall(object: o, pocket: pc)
                    guard Self.onCloth(ghost, spec: spec, margin: -0.004) else { continue }
                    let gm = EngineGeometry.mirror(ghost, across: rail, spec: spec)
                    guard let rp = EngineGeometry.railPoint(from: cue, toMirrored: gm, rail: rail, spec: spec),
                          !mustCross || rp.x > line,
                          EngineGeometry.pathClear(from: cue, to: rp, blockers: all),
                          EngineGeometry.pathClear(from: rp, to: ghost, blockers: others),
                          EngineGeometry.pathClear(from: o, to: pc, blockers: others) else { continue }
                    let pk = AnalyticP.kickPot(cue: cue, object: o, pocket: p, rail: rail, spec: spec, skill: skill)
                    guard pk > 0.01 else { continue }
                    let cut = EngineGeometry.angleBetween(ghost - rp, pc - o)
                    let v = AnalyticP.requiredSpeed(cueTravel: cue.distance(to: gm), obTravel: o.distance(to: pc),
                                                    cut: cut, rails: 1)
                    pots.append(Line(kind: .kick(rail), target: t, objectBall: t, pocket: p, aimPoint: gm, ghost: ghost,
                                     p: pk, minStep: Self.step(for: v)))
                }
            }
        }
        // Interleave: best hit-kicks first (they are what saves a snookered player), then kick-pots.
        let h = hits.sorted { $0.p > $1.p }, k = pots.sorted { $0.p > $1.p }
        var out: [Line] = []
        for i in 0..<max(h.count, k.count) {
            if i < h.count { out.append(h[i]) }
            if i < k.count { out.append(k[i]) }
        }
        return out
    }

    // MARK: Combos (chained ghosts)

    func usefulSecondBalls(_ g: GameState, objects: [BallID: Vec2], legal: Set<BallID>) -> Set<BallID> {
        if g.ruleSet == .wpaNine { return Set(objects.keys) }
        // 8-ball: own group (or the 8 when it is the target). On an open table any non-8 ball.
        if g.groups == nil { return Set(objects.keys).subtracting([.eight]) }
        return legal
    }

    func combos(cue: Vec2, objects: [BallID: Vec2], targets: [BallID], useful: Set<BallID>, spec: TableSpec) -> [Line] {
        var lines: [Line] = []
        for t in targets {
            let first = objects[t]!
            for second in useful.sorted() where second != t {
                let o = objects[second]!
                guard first.distance(to: o) < 0.6, cue.distance(to: first) < 1.6 else { continue }
                let others = Self.blockers(objects, except: [t, second])
                for p in Pocket.allCases {
                    let pc = spec.pocketCenter(p)
                    let ghost2 = AimGeometry.ghostBall(object: o, pocket: pc)
                    let ghost1 = AimGeometry.ghostBall(object: first, pocket: ghost2)
                    guard Self.onCloth(ghost1, spec: spec, margin: -0.004),
                          EngineGeometry.pathClear(from: cue, to: ghost1, blockers: others + [o]),
                          EngineGeometry.pathClear(from: first, to: ghost2, blockers: others),
                          EngineGeometry.pathClear(from: o, to: pc, blockers: others + [first]) else { continue }
                    let pc2 = AnalyticP.combo(cue: cue, first: first, second: o, pocket: p, spec: spec, skill: skill)
                    guard pc2 > 0.01 else { continue }
                    let cut1 = EngineGeometry.angleBetween(ghost1 - cue, ghost2 - first)
                    let v = AnalyticP.requiredSpeed(cueTravel: cue.distance(to: ghost1),
                                                    obTravel: first.distance(to: o) + o.distance(to: pc) * 1.6, cut: cut1)
                    lines.append(Line(kind: .combo(via: second), target: t, objectBall: second, pocket: p,
                                      aimPoint: ghost1, ghost: ghost1, p: pc2, minStep: Self.step(for: v)))
                }
            }
        }
        return lines.sorted { $0.p > $1.p }
    }

    // MARK: Safeties (engine.md §4.4 coarse set)

    func safetyStrokes(cue: Vec2, objects: [BallID: Vec2], targets: [BallID], spec: TableSpec) -> [(BallID, Vec2, Int)] {
        var out: [(BallID, Vec2, Int)] = []
        let R = EngineGeometry.R
        let legal = Set(targets)
        // Thickness-based: full, half-ball and thin either side of each legal ball, two soft speeds.
        for t in targets {
            let o = objects[t]!
            let u = (o - cue).normalized
            let others = Self.blockers(objects, except: [t])
            for off in [0, R, -R, 1.7 * R, -1.7 * R] {
                let aim = o + u.perpendicular * off
                guard EngineGeometry.pathClear(from: cue, to: aim, blockers: others) else { continue }
                for step in [1, 2] { out.append((t, aim - cue, step)) }
            }
        }
        // Coarse 10° grid at step 2, kept when the first ball on the straight line is legal.
        for k in 0..<36 {
            let a = Double(k) * 10 * Self.degree
            let d = Vec2(cos(a), sin(a))
            if let hit = Self.firstHit(from: cue, direction: d, objects: objects), legal.contains(hit) {
                out.append((hit, d, 2))
            }
        }
        return out
    }

    /// First object ball a straight cue-ball path touches (ignores rails).
    static func firstHit(from c: Vec2, direction d: Vec2, objects: [BallID: Vec2]) -> BallID? {
        let r = 2 * EngineGeometry.R
        var best: (BallID, Double)?
        for id in objects.keys.sorted() {
            let o = objects[id]!
            let t = (o - c).dot(d)
            guard t > 0 else { continue }
            let perp2 = (o - c).lengthSquared - t * t
            guard perp2 < r * r else { continue }
            let hitT = t - (r * r - perp2).squareRoot()
            if best == nil || hitT < best!.1 { best = (id, hitT) }
        }
        return best?.0
    }

    // MARK: Ball in hand

    func bihPlacements(_ objects: [BallID: Vec2], targets: [BallID], spec: TableSpec, kitchen: Bool) -> [Vec2?] {
        var scored: [(Vec2, Double)] = []
        let all = Self.blockers(objects, except: [])
        func ok(_ q: Vec2) -> Bool {
            guard Self.onCloth(q, spec: spec, margin: 0.003) else { return false }
            if kitchen && q.x >= spec.headStringX - 0.005 { return false }
            return all.allSatisfy { $0.distance(to: q) > 2 * EngineGeometry.R + 0.003 }
        }
        for t in targets {
            let o = objects[t]!
            let others = Self.blockers(objects, except: [t])
            for p in Pocket.allCases {
                let pc = spec.pocketCenter(p)
                guard EngineGeometry.pathClear(from: o, to: pc, blockers: others) else { continue }
                let u = (pc - o).normalized
                let ghost = AimGeometry.ghostBall(object: o, pocket: pc)
                let dists = kitchen ? [0.3, 0.6, 0.9, 1.2] : [0.15, 0.30, 0.45]
                for dist in dists {
                    for ang in [0.0, 25, -25] {
                        let q = ghost - u.rotated(by: ang * Self.degree) * dist
                        guard ok(q), EngineGeometry.pathClear(from: q, to: ghost, blockers: others) else { continue }
                        scored.append((q, AnalyticP.direct(cue: q, object: o, pocket: p, spec: spec, skill: skill)))
                    }
                }
            }
        }
        // Stable order: by P, then coordinates.
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : ($0.0.x, $0.0.y) < ($1.0.x, $1.0.y) }
        var picks: [Vec2?] = scored.prefix(caps.ballInHandPlacements).map { $0.0 }
        if picks.isEmpty {
            // Nothing pottable: a default spot to play safe / kick from.
            let base = kitchen ? Vec2(spec.headStringX - 0.15, spec.width / 2) : spec.headSpot
            for k in 0..<12 {
                let q = base + Vec2(0, (k % 2 == 0 ? 1 : -1) * Double(k / 2) * 0.06)
                if ok(q) { picks = [q]; break }
            }
        }
        return picks
    }

    func breakPlacements(_ objects: [BallID: Vec2], spec: TableSpec) -> [(Vec2, (BallID, Vec2))] {
        guard let apex = objects.min(by: { ($0.value.x, $0.key.number) < ($1.value.x, $1.key.number) }) else { return [] }
        let x = spec.headStringX - 0.05
        return [spec.width / 2, spec.width / 2 - 0.25, spec.width / 2 + 0.25].map { y in
            (Vec2(x, y), (apex.key, apex.value))
        }
    }
}
