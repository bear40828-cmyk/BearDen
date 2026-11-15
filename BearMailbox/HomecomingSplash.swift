import SwiftUI
import UIKit

/// Launch animation: a small HUD around a thumbnail, which shatters into line
/// fragments; the fragments re-assemble into full-screen line art, which then
/// crossfades into the full-colour artwork and collapses like a shutter.
/// Line art comes from bundled `splash-lines.json` (normalised polylines).
/// About 10.4 s; tap anywhere to skip. Shown once per cold launch.
struct HomecomingSplashView: View {
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var finished = false
    @State private var reducedOpacity = 0.0

    // Light dreamy background: cream -> pale pink -> pale lavender
    static let backgroundColors = [Color(red: 1.0, green: 0.973, blue: 0.941),
                                   Color(red: 0.992, green: 0.894, blue: 0.933),
                                   Color(red: 0.922, green: 0.886, blue: 0.988)]
    static let background = Gradient(colors: backgroundColors)
    private static let total: Double = 10.0

    var body: some View {
        ZStack {
            LinearGradient(gradient: Self.background, startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            if reduceMotion {
                if let art = SplashArt.shared.image {
                    Image(uiImage: art).resizable().scaledToFit()
                        .ignoresSafeArea()
                        .opacity(reducedOpacity)
                }
            } else {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSince(start)
                    Canvas { context, size in
                        SplashRenderer.draw(&context, size: size, t: SplashRenderer.phaseTime(t), wall: t)
                    }
                    .ignoresSafeArea()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .task {
            start = Date()
            if reduceMotion {
                withAnimation(.easeInOut(duration: 0.6)) { reducedOpacity = 1 }
                try? await Task.sleep(for: .milliseconds(1300))
            } else {
                try? await Task.sleep(for: .milliseconds(Int(Self.total * 1000)))
            }
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinished()
    }
}

/// Precomputed segment data, loaded once.
private final class SplashArt {
    static let shared = SplashArt()

    struct Segment {
        let a: CGPoint, b: CGPoint          // normalised target endpoints
        let scatter: CGVector               // fly-in start offset (fraction of screen)
        let spin: Double                    // fly-in start rotation (radians)
        let delay: Double                   // fly-in delay (s)
    }

    struct Fragment {
        let a: CGPoint, b: CGPoint          // normalised inside the thumbnail/title box
        let inTitle: Bool
        let drift: CGVector                 // outward drift (points)
        let spin: Double
    }

    let image: UIImage?
    let thumbnail: UIImage?
    /// 2–3 lines picked at random from splash-quotes.txt (one per line), once per launch.
    let quotes: [String]
    let aspect: CGFloat
    let segments: [Segment]
    let fragments: [Fragment]

    private init() {
        image = UIImage(named: "SplashArt.png") ?? UIImage(named: "SplashArt.jpg")
        thumbnail = UIImage(named: "SplashThumb.jpg") ?? UIImage(named: "SplashArt.jpg")
        let pool = (Bundle.main.url(forResource: "splash-quotes", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        quotes = Array(pool.shuffled().prefix(Int.random(in: 2...3)))
        var rng = SplashRNG(seed: 0x5EED)
        var segs: [Segment] = []
        var aspect: CGFloat = 0.5628
        if let url = Bundle.main.url(forResource: "splash-lines", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let value = json["aspect"] as? NSNumber { aspect = CGFloat(value.doubleValue) }
            for line in json["lines"] as? [[[NSNumber]]] ?? [] {
                let pts = line.compactMap { $0.count == 2 ? CGPoint(x: $0[0].doubleValue, y: $0[1].doubleValue) : nil }
                guard pts.count > 1 else { continue }
                for i in 1..<pts.count {
                    let angle = rng.next() * 2 * .pi
                    let dist = 0.25 + rng.next() * 0.55
                    segs.append(Segment(
                        a: pts[i - 1], b: pts[i],
                        scatter: CGVector(dx: cos(angle) * dist, dy: sin(angle) * dist),
                        spin: (rng.next() - 0.5) * 4,
                        delay: rng.next() * 0.4))
                }
            }
        }
        self.aspect = aspect
        segments = segs

        // Thumbnail fragments: a sample of the line art cropped into the square thumbnail.
        var frags: [Fragment] = []
        let step = max(1, segs.count / 380)
        let cropHeight = 1 / aspect                  // square crop: full width, centred vertically
        let top = (cropHeight - 1) / 2
        for i in stride(from: 0, to: segs.count, by: step) {
            let s = segs[i]
            let a = CGPoint(x: s.a.x, y: s.a.y * cropHeight - top)
            let b = CGPoint(x: s.b.x, y: s.b.y * cropHeight - top)
            guard (0...1).contains(a.y), (0...1).contains(b.y) else { continue }
            let angle = rng.next() * 2 * .pi
            let dist = 60 + rng.next() * 160
            frags.append(Fragment(a: a, b: b, inTitle: false,
                                  drift: CGVector(dx: cos(angle) * dist, dy: sin(angle) * dist),
                                  spin: (rng.next() - 0.5) * 3))
        }
        for _ in 0..<60 {
            let x = rng.next(), y = rng.next()
            let len = 0.05 + rng.next() * 0.12
            let angle = rng.next() * 2 * .pi
            let dist = 40 + rng.next() * 120
            frags.append(Fragment(a: CGPoint(x: x, y: y), b: CGPoint(x: min(1, x + len), y: y), inTitle: true,
                                  drift: CGVector(dx: cos(angle) * dist, dy: sin(angle) * dist),
                                  spin: (rng.next() - 0.5) * 3))
        }
        fragments = frags
    }
}

private struct SplashRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

private enum SplashRenderer {
    static let lineColor = Color(red: 0.74, green: 0.38, blue: 0.74)
    static let hudColor = Color(red: 0.78, green: 0.38, blue: 0.60)
    /// Maps wall-clock time (0–10.0 s) onto the renderer's compact phase clock (0–3.5):
    /// HUD 0–3.5, shatter 3.5–4.4, assemble 4.4–6.5, hold line art 6.5–7.5,
    /// colour reveal 7.5–8.1, hold 8.1–9.6, shutter 9.6–10.0.
    static func phaseTime(_ t: Double) -> Double {
        let keys: [(Double, Double)] = [(0, 0), (3.5, 0.8), (4.4, 1.3), (6.5, 2.3), (7.5, 2.3),
                                        (8.1, 2.9), (9.6, 3.15), (10.0, 3.5)]
        guard t > 0 else { return 0 }
        for i in 1..<keys.count where t <= keys[i].0 {
            let (t0, p0) = keys[i - 1], (t1, p1) = keys[i]
            return p0 + (t - t0) / (t1 - t0) * (p1 - p0)
        }
        return 3.5
    }

    static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
    static func easeInOut(_ v: Double) -> Double { let x = clamp(v); return x * x * (3 - 2 * x) }
    static func easeOut(_ v: Double) -> Double { let x = clamp(v); return 1 - pow(1 - x, 3) }

    /// `t` is the phase clock (see `phaseTime`); `wall` is real seconds, used for
    /// continuous HUD motion so it stays lively while the phase clock is stretched.
    static func draw(_ context: inout GraphicsContext, size: CGSize, t: Double, wall: Double) {
        let art = SplashArt.shared
        let center = CGPoint(x: size.width / 2, y: size.height / 2 - 40)
        let thumbSide: CGFloat = 84
        let thumbRect = CGRect(x: center.x - thumbSide / 2, y: center.y - thumbSide / 2, width: thumbSide, height: thumbSide)
        let titleRect = CGRect(x: center.x - 48, y: center.y + 124, width: 96, height: 30)

        // Aspect-fit rect (whole image visible) shared by the line art and the image.
        let scale = min(size.width / art.aspect, size.height)
        let artSize = CGSize(width: art.aspect * scale, height: scale)
        let artRect = CGRect(x: (size.width - artSize.width) / 2, y: (size.height - artSize.height) / 2,
                             width: artSize.width, height: artSize.height)
        func project(_ p: CGPoint) -> CGPoint {
            CGPoint(x: artRect.minX + p.x * artRect.width, y: artRect.minY + p.y * artRect.height)
        }

        // Final phase: shutter collapse and background fade revealing the app.
        let collapse = easeInOut((t - 3.15) / 0.35)
        let bgAlpha = 1 - easeOut((t - 3.3) / 0.2)
        var bg = context
        bg.opacity = bgAlpha
        bg.fill(Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(HomecomingSplashView.background, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

        // 1. HUD
        if t < 1.3 {
            let fadeIn = easeOut(t / 0.4)
            let fadeOut = 1 - easeInOut((t - 0.8) / 0.4)
            let alpha = fadeIn * fadeOut
            var hud = context
            hud.opacity = alpha
            let r: CGFloat = 70
            hud.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                       with: .color(hudColor.opacity(0.7)), lineWidth: 1)
            var ticks = Path()
            for i in 0..<60 {
                let a = Double(i) / 60 * 2 * .pi
                let inner = r + (i % 5 == 0 ? 4 : 6), outer = r + 10
                let ca = CGFloat(Foundation.cos(a)), sa = CGFloat(Foundation.sin(a))
                ticks.move(to: CGPoint(x: center.x + ca * inner, y: center.y + sa * inner))
                ticks.addLine(to: CGPoint(x: center.x + ca * outer, y: center.y + sa * outer))
            }
            hud.stroke(ticks, with: .color(hudColor.opacity(0.55)), lineWidth: 1)
            // Pulse ring expanding outward
            let pulse = wall.truncatingRemainder(dividingBy: 1.6) / 1.6
            let pr = r + 12 + CGFloat(pulse) * 46
            hud.stroke(Path(ellipseIn: CGRect(x: center.x - pr, y: center.y - pr, width: pr * 2, height: pr * 2)),
                       with: .color(hudColor.opacity(0.35 * (1 - pulse))), lineWidth: 1)
            let r2: CGFloat = 92
            var dashed = hud
            dashed.translateBy(x: center.x, y: center.y)
            dashed.rotate(by: .radians(wall * 0.5))
            dashed.stroke(Path(ellipseIn: CGRect(x: -r2, y: -r2, width: r2 * 2, height: r2 * 2)),
                          with: .color(hudColor.opacity(0.45)),
                          style: StrokeStyle(lineWidth: 1.2, dash: [10, 7]))
            // Thumbnail and title (whole until the shatter starts)
            if t < 0.8 {
                // Thumbnail breathing
                let breath = 1 + 0.035 * CGFloat(Foundation.sin(wall * 2.4))
                let side = thumbSide * breath
                let box = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
                if let image = art.thumbnail {
                    var thumb = hud
                    thumb.clip(to: Path(roundedRect: box, cornerRadius: 18 * breath))
                    // aspect-fill into the square box
                    let ia = image.size.width / max(1, image.size.height)
                    let w = ia >= 1 ? side * ia : side, h = ia >= 1 ? side : side / ia
                    thumb.draw(Image(uiImage: image), in: CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
                }
                hud.stroke(Path(roundedRect: box, cornerRadius: 18 * breath), with: .color(hudColor.opacity(0.6)), lineWidth: 1)
                // Title clip-reveal from left to right
                let reveal = easeOut((wall - 0.9) / 1.0)
                if reveal > 0 {
                    var title = hud
                    title.clip(to: Path(CGRect(x: titleRect.minX - 10, y: titleRect.minY - 6,
                                               width: (titleRect.width + 20) * CGFloat(reveal), height: titleRect.height + 12)))
                    title.draw(Text("熊窝").font(.system(size: 22, weight: .semibold, design: .rounded)).tracking(10).foregroundColor(hudColor),
                               at: CGPoint(x: titleRect.midX, y: titleRect.midY))
                }
                // Short lines picked at launch, fading in one after another
                for (i, line) in art.quotes.enumerated() {
                    let a = easeOut((wall - 1.3 - Double(i) * 0.6) / 0.5)
                    guard a > 0 else { continue }
                    let color = i % 2 == 0 ? hudColor : lineColor
                    hud.draw(Text(line).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(color.opacity(0.85 * a)),
                             at: CGPoint(x: titleRect.midX, y: titleRect.maxY + 20 + CGFloat(i) * 22 - CGFloat(1 - a) * 6))
                }
            }
        }

        // 2. Shatter
        if t >= 0.8 && t < 1.4 {
            let p = easeOut((t - 0.8) / 0.5)
            var path = Path()
            for f in art.fragments {
                let box = f.inTitle ? titleRect : thumbRect
                let a = CGPoint(x: box.minX + f.a.x * box.width, y: box.minY + f.a.y * box.height)
                let b = CGPoint(x: box.minX + f.b.x * box.width, y: box.minY + f.b.y * box.height)
                appendSegment(&path, a, b, offset: CGVector(dx: f.drift.dx * p, dy: f.drift.dy * p), spin: f.spin * p)
            }
            context.stroke(path, with: .color(lineColor.opacity(0.9 * (1 - p))), lineWidth: 1)
        }

        // 3. Assemble line art, 4. crossfade to the image
        let imageAlpha = easeInOut((t - 2.3) / 0.6)
        if t >= 1.3 && imageAlpha < 1 {
            var path = Path()
            var settled = 0.0
            for s in art.segments {
                let e = easeInOut((t - 1.3 - s.delay) / 0.6)
                settled += e
                guard e > 0 else { continue }
                let k = 1 - e
                appendSegment(&path, project(s.a), project(s.b),
                              offset: CGVector(dx: s.scatter.dx * size.width * k, dy: s.scatter.dy * size.height * k),
                              spin: s.spin * k)
            }
            let progress = art.segments.isEmpty ? 1 : settled / Double(art.segments.count)
            let alpha = (0.35 + 0.65 * progress) * (1 - imageAlpha)
            var glow = context
            glow.addFilter(.blur(radius: 3))
            glow.stroke(path, with: .color(lineColor.opacity(0.5 * alpha)), lineWidth: 2.5)
            context.stroke(path, with: .color(lineColor.opacity(alpha)), lineWidth: 0.9)
        }

        // 4–5. Image, hold, then shutter collapse
        if imageAlpha > 0, let image = art.image {
            var layer = context
            let visibleHeight = max(1.5, size.height * (1 - collapse))
            layer.clip(to: Path(CGRect(x: 0, y: (size.height - visibleHeight) / 2, width: size.width, height: visibleHeight)))
            layer.opacity = imageAlpha * bgAlpha
            // Soft blurred copy fills any area the aspect-fit image leaves empty.
            let fill = max(size.width / artRect.width, size.height / artRect.height)
            let fillSize = CGSize(width: artRect.width * fill, height: artRect.height * fill)
            var backdrop = layer
            backdrop.addFilter(.blur(radius: 24))
            backdrop.draw(Image(uiImage: image), in: CGRect(x: (size.width - fillSize.width) / 2, y: (size.height - fillSize.height) / 2,
                                                            width: fillSize.width, height: fillSize.height))
            layer.draw(Image(uiImage: image), in: artRect)

            if collapse > 0.85 {
                context.fill(Path(CGRect(x: 0, y: size.height / 2 - 0.75, width: size.width, height: 1.5)),
                             with: .color(lineColor.opacity(bgAlpha)))
            }
        }
    }

    private static func appendSegment(_ path: inout Path, _ a: CGPoint, _ b: CGPoint, offset: CGVector, spin: Double) {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let c = cos(spin), s = sin(spin)
        func rotate(_ p: CGPoint) -> CGPoint {
            let dx = p.x - mid.x, dy = p.y - mid.y
            return CGPoint(x: mid.x + dx * c - dy * s + offset.dx, y: mid.y + dx * s + dy * c + offset.dy)
        }
        path.move(to: rotate(a))
        path.addLine(to: rotate(b))
    }
}
