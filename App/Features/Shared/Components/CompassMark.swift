import SwiftUI

// The Odyssey brand mark: the app icon's glyph without its tile. A bold ring holds a faceted
// compass star, and only the north ray breaks out through it. The ring gap and the hub are
// cut out rather than painted, so the mark sits on any background. Decorative only.
struct CompassMark: View {
    var size: CGFloat = 30
    var tint: Color = Theme.heroAccent

    var body: some View {
        Canvas { ctx, canvasSize in
            let g = MarkGeometry(size: canvasSize.width)
            let ring = Path(ellipseIn: CGRect(x: g.center.x - g.ringR, y: g.center.y - g.ringR,
                                              width: g.ringR * 2, height: g.ringR * 2))

            ctx.drawLayer { layer in
                layer.stroke(ring, with: .linearGradient(
                    Gradient(colors: [tint.mix(with: .white, by: 0.2), tint, tint.mix(with: .black, by: 0.45)]),
                    startPoint: .zero, endPoint: CGPoint(x: canvasSize.width, y: canvasSize.height)),
                    lineWidth: g.ringW)
                layer.blendMode = .destinationOut
                layer.stroke(g.rayOutline(0, length: g.north), with: .color(.black),
                             style: StrokeStyle(lineWidth: g.knock * 2, lineJoin: .round))
                layer.fill(g.rayOutline(0, length: g.north), with: .color(.black))
            }

            ctx.drawLayer { layer in
                if g.showsMinorRays {
                    for deg in [45.0, 135, 225, 315] {
                        drawRay(&layer, g, deg, length: g.minor, inner: g.minorInner,
                                lit: .color(tint.mix(with: .black, by: 0.55)),
                                shade: .color(tint.mix(with: .black, by: 0.68)))
                    }
                }
                for deg in [90.0, 180, 270] {
                    drawRay(&layer, g, deg, length: g.ray, inner: g.inner,
                            lit: .color(tint.mix(with: .black, by: 0.12)),
                            shade: .color(tint.mix(with: .black, by: 0.45)))
                }
                let tip = g.point(g.north, 0)
                let base = g.point(g.inner * 0.6, 0)
                drawRay(&layer, g, 0, length: g.north, inner: g.inner,
                        lit: .linearGradient(Gradient(colors: [tint.mix(with: .white, by: 0.55), .white]),
                                             startPoint: base, endPoint: tip),
                        shade: .linearGradient(Gradient(colors: [tint.mix(with: .black, by: 0.15),
                                                                 tint.mix(with: .white, by: 0.15)]),
                                               startPoint: base, endPoint: tip))
                layer.blendMode = .destinationOut
                layer.fill(g.circle(g.hubR), with: .color(.black))
            }
            ctx.fill(g.circle(g.dotR), with: .color(.white))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func drawRay(_ ctx: inout GraphicsContext, _ g: MarkGeometry, _ deg: Double,
                         length: CGFloat, inner: CGFloat, lit: GraphicsContext.Shading,
                         shade: GraphicsContext.Shading) {
        for side in [-1.0, 1.0] {
            var facet = Path()
            facet.move(to: g.center)
            facet.addLine(to: g.point(inner, deg + side * 45))
            facet.addLine(to: g.point(length, deg))
            facet.closeSubpath()
            ctx.fill(facet, with: g.isLit(deg, side) ? lit : shade)
        }
    }
}

// The app icon drawn natively: the mark on the icon's tile, for surfaces that aren't dark.
struct AppIconTile: View {
    var size: CGFloat = 60

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(.sRGB, red: 0.055, green: 0.290, blue: 0.271),
                             Color(.sRGB, red: 0.012, green: 0.098, blue: 0.102)],
                    startPoint: .top, endPoint: UnitPoint(x: 0.35, y: 1)))
            CompassMark(size: size * 0.7, tint: Theme.heroAccent)
                .offset(y: -size * 0.038)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// Proportions come from the 1024px icon (design/app-icon/make_icon.py), scaled so the
// glyph's bounding box (north tip to ring bottom) fills the frame height.
private struct MarkGeometry {
    let unit: CGFloat
    let center: CGPoint
    let ringR, ringW, north, ray, inner, minor, minorInner, knock, hubR, dotR: CGFloat
    let showsMinorRays: Bool

    init(size: CGFloat) {
        let u = size / 736
        unit = u
        center = CGPoint(x: size / 2, y: size / 2 + 52 * u)
        ringR = 294 * u
        ringW = max(44 * u, 1.5)
        north = 420 * u
        ray = 252 * u
        inner = 78 * u
        minor = 156 * u
        minorInner = 50 * u
        knock = max(24 * u, 1)
        dotR = max(15 * u, 1.3)
        hubR = max(31 * u, dotR + 1)
        showsMinorRays = size >= 48
    }

    func point(_ r: CGFloat, _ deg: Double) -> CGPoint {
        let a = (deg - 90) * .pi / 180
        return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
    }

    func rayOutline(_ deg: Double, length: CGFloat) -> Path {
        var p = Path()
        p.move(to: center)
        p.addLine(to: point(inner, deg - 45))
        p.addLine(to: point(length, deg))
        p.addLine(to: point(inner, deg + 45))
        p.closeSubpath()
        return p
    }

    func circle(_ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    }

    // Light comes from the upper left, as in the icon.
    func isLit(_ deg: Double, _ side: Double) -> Bool {
        let a = (deg + side * 90 - 90) * .pi / 180
        return cos(a) * -0.62 + sin(a) * -0.78 > 0
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 24) {
        HStack(spacing: 24) {
            CompassMark()
            CompassMark(size: 56)
            CompassMark(size: 96)
        }
        .padding()
        .background(Theme.heroFill)
        AppIconTile()
    }
    .padding()
}
#endif
