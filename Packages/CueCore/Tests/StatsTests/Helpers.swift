import Foundation
import Geometry
import Rules
@testable import Stats

let spec7 = TableSpec(size: .sevenFoot)
let R = TableSpec.ballRadius

func b(_ n: Int) -> BallID { BallID(n)! }

func table(_ balls: [Int: Vec2], spec: TableSpec = spec7) -> TableState {
    var s = TableState(spec: spec)
    for (n, p) in balls { s.balls[b(n)] = BallState(position: p) }
    return s
}

/// Copy of `pre` with the given balls marked pocketed.
func afterPocketing(_ pre: TableState, _ ns: [Int]) -> TableState {
    var s = pre
    for n in ns { s.balls[b(n)]?.motion = .pocketed }
    return s
}

/// Places the cue ball so that cutting `object` into `pocket` needs exactly `degrees` of cut,
/// with the cue ball `distance` metres from the ghost-ball position. `side` flips the cut direction.
func cuePosition(object: Vec2, pocket: Vec2, degrees: Double, distance: Double, side: Double = 1) -> Vec2 {
    let toPocket = (pocket - object).normalized
    let ghost = object - toPocket * (2 * R)
    let aim = toPocket.rotated(by: side * degrees * .pi / 180)
    return ghost - aim * distance
}

/// Simple pot: cue hits `object`, which drops in `pocket`.
func potTrace(_ object: Int, _ pocket: Pocket) -> ShotTraceSummary {
    ShotTraceSummary(events: [.ballBall(.cue, b(object)), .pocket(b(object), pocket)])
}

