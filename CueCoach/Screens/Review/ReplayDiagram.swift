import SwiftUI
import Geometry
import Rules

/// Static top-down shot diagram (D20: a still picture, not a playable table).
struct ReplayDiagram: View {
    var shot: ReviewShot
    var moment: GameReviewModel.ReplayMoment
    var showAlternative: Bool
    var tableSize: TableSize

    var body: some View {
        Canvas { ctx, size in
            let spec = shot.pre?.spec ?? TableSpec(size: tableSize)
            let railW = min(size.width, size.height * 2) * 0.045
            let felt = CGRect(x: railW, y: railW, width: size.width - 2 * railW, height: size.height - 2 * railW)
            let scale = felt.width / spec.length
            func pt(_ v: Vec2) -> CGPoint { CGPoint(x: felt.minX + v.x * scale, y: felt.minY + v.y * scale) }

            // Rails + felt
            let outer = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: railW * 0.8)
            ctx.fill(outer, with: .color(SBColor.rail))
            ctx.stroke(outer, with: .color(SBColor.railHighlight), lineWidth: 2)
            ctx.fill(Path(felt), with: .radialGradient(Gradient(colors: [SBColor.feltCenter, SBColor.feltEdge]),
                                                       center: CGPoint(x: felt.midX, y: felt.midY), startRadius: 0,
                                                       endRadius: felt.width * 0.6))
            let pocketR = spec.cornerMouth * scale * 0.55
            for p in spec.pockets {
                let c = pt(spec.pocketCenter(p))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - pocketR, y: c.y - pocketR, width: pocketR * 2, height: pocketR * 2)),
                         with: .color(SBColor.bg))
            }

            let r = TableSpec.ballRadius * scale

            // Engine alternative: dashed predict path + ghost cue outline.
            if showAlternative, let alt = shot.alternative {
                let dash = StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 6])
                ctx.stroke(polyline(alt.cuePath.map(pt)), with: .color(SBColor.predict), style: dash)
                ctx.stroke(polyline(alt.objectPath.map(pt)), with: .color(SBColor.predict), style: dash)
                let g = pt(alt.ghostCue)
                ctx.stroke(Path(ellipseIn: CGRect(x: g.x - r, y: g.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(SBColor.aim), lineWidth: 2)
            }

            // Actual paths: cue in ink, object balls in their colour.
            for (id, path) in shot.paths.sorted(by: { $0.key < $1.key }) where path.count > 1 {
                ctx.stroke(polyline(path.map(pt)), with: .color(id.isCue ? SBColor.ink : Self.ballColor(id)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
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
                        ctx.stroke(Path(ellipseIn: rect), with: .color(SBColor.ink.opacity(0.6)), lineWidth: 1)
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
                               with: .color(id.isCue ? SBColor.danger : Self.ballColor(id)), lineWidth: 2)
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
                ctx.stroke(x, with: .color(SBColor.danger), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
        .aspectRatio(2.18, contentMode: .fit)
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
            ctx.fill(circle, with: .color(.white))
        } else if id.number > 8 {
            ctx.fill(circle, with: .color(.white))
            var inner = ctx
            inner.clip(to: circle)
            inner.fill(Path(rect.insetBy(dx: 0, dy: rect.height * 0.22)), with: .color(Self.ballColor(id)))
        } else {
            ctx.fill(circle, with: .color(Self.ballColor(id)))
        }
    }

    static func ballColor(_ id: BallID) -> Color {
        switch (id.number - 1) % 8 + 1 {
        case 1: Color(hex: 0xF5C518)
        case 2: Color(hex: 0x1E40AF)
        case 3: Color(hex: 0xDC2626)
        case 4: Color(hex: 0x6D28D9)
        case 5: Color(hex: 0xEA580C)
        case 6: Color(hex: 0x15803D)
        case 7: Color(hex: 0x7F1D1D)
        default: Color(hex: 0x111111)
        }
    }
}
