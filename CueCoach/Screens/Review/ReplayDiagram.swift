import SwiftUI
import Geometry
import Rules

/// Maps table metres into a canvas with one scale on both axes, so the felt keeps the table's 2:1 and every
/// pocket lands inside the canvas whatever its aspect. The table (felt + rail frame) is centred.
struct ReplayLayout {
    /// Rail frame width as a fraction of the table's playing width.
    static let railFraction = 0.1

    /// Canvas aspect that the table fills exactly.
    static func aspect(_ spec: TableSpec) -> CGFloat {
        let rail = spec.width * railFraction
        return (spec.length + 2 * rail) / (spec.width + 2 * rail)
    }

    let scale: CGFloat
    let table: CGRect
    let felt: CGRect
    var railWidth: CGFloat { felt.minX - table.minX }

    init(size: CGSize, spec: TableSpec) {
        let rail = spec.width * Self.railFraction
        let s = max(0, min(size.width / (spec.length + 2 * rail), size.height / (spec.width + 2 * rail)))
        let w = (spec.length + 2 * rail) * s, h = (spec.width + 2 * rail) * s
        scale = s
        table = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        felt = table.insetBy(dx: rail * s, dy: rail * s)
    }

    func point(_ v: Vec2) -> CGPoint { CGPoint(x: felt.minX + v.x * scale, y: felt.minY + v.y * scale) }
}

/// Static top-down shot diagram (D20: a still picture, not a playable table).
struct ReplayDiagram: View {
    var shot: ReviewShot
    var moment: GameReviewModel.ReplayMoment
    var showAlternative: Bool
    var tableSize: TableSize

    private var spec: TableSpec { shot.pre?.spec ?? TableSpec(size: tableSize) }

    var body: some View {
        Canvas { ctx, size in
            let spec = self.spec
            let layout = ReplayLayout(size: size, spec: spec)
            let felt = layout.felt, scale = layout.scale, railW = layout.railWidth
            func pt(_ v: Vec2) -> CGPoint { layout.point(v) }

            // Rails + felt
            let outer = Path(roundedRect: layout.table, cornerRadius: railW * 0.8)
            ctx.fill(outer, with: .color(AX.rail))
            ctx.stroke(outer, with: .color(AX.railHighlight), lineWidth: 2)
            ctx.fill(Path(felt), with: .radialGradient(Gradient(colors: [AX.felt, AX.feltEdge]),
                                                       center: CGPoint(x: felt.midX, y: felt.midY), startRadius: 0,
                                                       endRadius: felt.width * 0.6))
            let pocketR = spec.cornerMouth * scale * 0.55
            for p in spec.pockets {
                let c = pt(spec.pocketCenter(p))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - pocketR, y: c.y - pocketR, width: pocketR * 2, height: pocketR * 2)),
                         with: .color(AX.page))
            }

            let r = TableSpec.ballRadius * scale

            // Engine alternative: dashed predict path + ghost cue outline.
            if showAlternative, let alt = shot.alternative {
                let dash = StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 6])
                ctx.stroke(polyline(alt.cuePath.map(pt)), with: .color(AX.onDark.opacity(0.5)), style: dash)
                ctx.stroke(polyline(alt.objectPath.map(pt)), with: .color(AX.onDark.opacity(0.5)), style: dash)
                let g = pt(alt.ghostCue)
                ctx.stroke(Path(ellipseIn: CGRect(x: g.x - r, y: g.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(AX.onDark), lineWidth: 2)
            }

            if shot.pathsAreTraced {
                // Actual (traced) paths: cue in ink, object balls in their colour.
                for (id, path) in shot.paths.sorted(by: { $0.key < $1.key }) where path.count > 1 {
                    ctx.stroke(polyline(path.map(pt)), with: .color(id.isCue ? AX.ink : Self.ballColor(id)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            } else {
                // Inferred: no claim about the route, only where each ball went (faint start→end arrow).
                for (_, path) in shot.paths.sorted(by: { $0.key < $1.key }) where path.count > 1 {
                    arrow(&ctx, from: pt(path[0]), to: pt(path[path.count - 1]), inset: r)
                }
            }

            // Balls
            let state = moment == .before ? shot.pre : shot.post
            if let state {
                for (id, b) in state.balls.sorted(by: { $0.key < $1.key }) where b.motion != .pocketed {
                    let c = pt(b.position)
                    let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
                    if moment == .before {
                        ctx.opacity = 0.4
                        drawBall(&ctx, id, rect)
                        ctx.opacity = 1
                        ctx.stroke(Path(ellipseIn: rect), with: .color(AX.ink.opacity(0.6)), lineWidth: 1)
                    } else {
                        drawBall(&ctx, id, rect)
                    }
                }
            }
            // Pocketed: small ring inside the pocket.
            if moment == .after {
                for (id, p) in shot.pocketed {
                    let c = pt(spec.pocketCenter(p))
                    let rr = pocketR * 0.55
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)),
                               with: .color(id.isCue ? AX.danger : Self.ballColor(id)), lineWidth: 2)
                }
            }
            // Fouls: danger × at the scratch pocket or the cue ball's resting point.
            if !shot.fouls.isEmpty {
                let at: CGPoint
                if let p = shot.pocketed[.cue] { at = pt(spec.pocketCenter(p)) }
                else if let c = shot.post?.balls[.cue]?.position { at = pt(c) }
                else { at = CGPoint(x: felt.midX, y: felt.midY) }
                let k = r * 1.4
                var x = Path()
                x.move(to: CGPoint(x: at.x - k, y: at.y - k)); x.addLine(to: CGPoint(x: at.x + k, y: at.y + k))
                x.move(to: CGPoint(x: at.x + k, y: at.y - k)); x.addLine(to: CGPoint(x: at.x - k, y: at.y + k))
                ctx.stroke(x, with: .color(AX.danger), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
        .aspectRatio(ReplayLayout.aspect(spec), contentMode: .fit)
    }

    private func arrow(_ ctx: inout GraphicsContext, from a: CGPoint, to b: CGPoint, inset: CGFloat) {
        let dx = b.x - a.x, dy = b.y - a.y, len = (dx * dx + dy * dy).squareRoot()
        guard len > inset * 3 else { return }
        let ux = dx / len, uy = dy / len
        let s = CGPoint(x: a.x + ux * inset, y: a.y + uy * inset), e = CGPoint(x: b.x - ux * inset, y: b.y - uy * inset)
        let head = max(5, inset * 1.2)
        var p = Path()
        p.move(to: s); p.addLine(to: e)
        p.move(to: CGPoint(x: e.x - ux * head - uy * head * 0.6, y: e.y - uy * head + ux * head * 0.6))
        p.addLine(to: e)
        p.addLine(to: CGPoint(x: e.x - ux * head + uy * head * 0.6, y: e.y - uy * head - ux * head * 0.6))
        ctx.stroke(p, with: .color(AX.ink.opacity(0.35)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    private func polyline(_ pts: [CGPoint]) -> Path {
        var p = Path()
        guard let f = pts.first else { return p }
        p.move(to: f)
        for q in pts.dropFirst() { p.addLine(to: q) }
        return p
    }

    private func drawBall(_ ctx: inout GraphicsContext, _ id: BallID, _ rect: CGRect) {
        let circle = Path(ellipseIn: rect)
        if id.isCue {
            ctx.fill(circle, with: .color(AX.ballWhite))
        } else if id.number > 8 {
            ctx.fill(circle, with: .color(AX.ballWhite))
            var inner = ctx
            inner.clip(to: circle)
            inner.fill(Path(rect.insetBy(dx: 0, dy: rect.height * 0.22)), with: .color(Self.ballColor(id)))
        } else {
            ctx.fill(circle, with: .color(Self.ballColor(id)))
        }
    }

    static func ballColor(_ id: BallID) -> Color { AX.ball(id.number) }
}
