import SwiftUI

/// A selection indicator. Increment `activation` when the reasoning panel closes.
/// The reference shows one damped return, followed by a stationary needle.
struct ReasoningDial: View {
    let value: String
    let levels: [String]
    let activation: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var angle: Double {
        ReasoningScale.angle(value: value, levels: levels)
    }

    private var displacement: Double { angle <= 60 ? 60 : -60 }

    var body: some View {
        let restAngle = angle
        let initialDisplacement = displacement
        Group {
            if reduceMotion {
                ReasoningDialFace(angle: restAngle)
            } else {
                ReasoningDialFace(angle: restAngle)
                    .keyframeAnimator(initialValue: 0.0, trigger: activation) { _, offset in
                        ReasoningDialFace(angle: restAngle + offset)
                    } keyframes: { _ in
                        MoveKeyframe(initialDisplacement)
                        SpringKeyframe(0.0, duration: 0.42,
                                       spring: Spring(response: 0.28, dampingRatio: 0.60),
                                       startVelocity: 0.0)
                    }
            }
        }
        .frame(width: 24, height: 23)
        .accessibilityHidden(true)
    }
}

private struct ReasoningDialFace: View {
    let angle: Double

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2 + 1)
            let radius: CGFloat = 10.75
            let visibleAngle = min(120, max(-120, angle))
            let ringStyle = StrokeStyle(lineWidth: 2.1, lineCap: .round)

            var track = Path()
            track.addArc(center: center, radius: radius,
                         startAngle: .degrees(-210), endAngle: .degrees(30), clockwise: false)
            context.stroke(track, with: .color(.primary.opacity(0.25)), style: ringStyle)

            var progress = Path()
            progress.addArc(center: center, radius: radius,
                            startAngle: .degrees(-210), endAngle: .degrees(visibleAngle - 90),
                            clockwise: false)
            context.stroke(progress, with: .color(ZTheme.accent), style: ringStyle)

            let radians = visibleAngle * .pi / 180
            let direction = CGVector(dx: sin(radians), dy: -cos(radians))
            var needle = Path()
            needle.move(to: CGPoint(x: center.x + direction.dx * 2.2,
                                    y: center.y + direction.dy * 2.2))
            needle.addLine(to: CGPoint(x: center.x + direction.dx * 7.8,
                                      y: center.y + direction.dy * 7.8))
            context.stroke(needle, with: .color(.primary),
                           style: StrokeStyle(lineWidth: 2.05, lineCap: .round))

            let hub = Path(ellipseIn: CGRect(x: center.x - 2.3, y: center.y - 2.3,
                                            width: 4.6, height: 4.6))
            context.stroke(hub, with: .color(.primary), lineWidth: 1.8)
        }
    }
}
