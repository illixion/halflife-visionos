//
//  FingerGunAnimation.swift
//  LambdaVision
//
//  A drawn loop of the finger-gun gesture for the Hands page: the hand
//  points, the index finger curls to pull the trigger, the muzzle flashes
//  and the hand kicks back. It stands in until there is a recording of a
//  real hand (a clip named "fingerGun" in Previews takes its place).
//

import SwiftUI

struct FingerGunAnimation: View {
    private let period = 2.4

    var body: some View {
        if let found = PreviewAssets.find("fingerGun") {
            PreviewMediaFile(found: found)
        } else {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                Canvas { context, size in draw(&context, size: size, t: t) }
            }
            .background(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)],
                                       startPoint: .top, endPoint: .bottom))
        }
    }

    /// 0 → 1 → 0 curl of the trigger finger: pulled at 0.45, back by 0.6.
    private func curl(_ t: Double) -> Double {
        switch t {
        case ..<0.35: 0
        case ..<0.45: (t - 0.35) / 0.1
        case ..<0.6: 1 - (t - 0.45) / 0.15
        default: 0
        }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, t: Double) {
        let c = curl(t)
        let kick = c > 0.5 ? (1 - abs(c - 1)) : c * 0.5
        let unit = min(size.width, size.height * 1.6) / 100
        let origin = CGPoint(x: size.width * 0.38, y: size.height * 0.62)
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: origin.x + x * unit, y: origin.y + y * unit)
        }
        let skin = Color(red: 0.93, green: 0.74, blue: 0.62)
        let shade = Color(red: 0.78, green: 0.58, blue: 0.48)

        // The hand tips back a little when it fires.
        var hand = context
        hand.translateBy(x: origin.x, y: origin.y)
        hand.rotate(by: .degrees(-kick * 7))
        hand.translateBy(x: -origin.x, y: -origin.y)

        // Palm and the three closed fingers.
        hand.fill(Path(roundedRect: CGRect(x: point(-14, -14).x, y: point(-14, -14).y,
                                           width: 30 * unit, height: 30 * unit),
                       cornerRadius: 9 * unit), with: .color(skin))
        for i in 0..<3 {
            let y = -12 + Double(i) * 8
            hand.fill(Path(roundedRect: CGRect(x: point(8, y + 4).x, y: point(8, y + 4).y,
                                               width: 13 * unit, height: 7 * unit),
                           cornerRadius: 3.5 * unit), with: .color(shade))
        }
        // The thumb, up.
        var thumb = Path()
        thumb.move(to: point(-6, -14))
        thumb.addLine(to: point(-4, -34))
        hand.stroke(thumb, with: .color(skin), style: StrokeStyle(lineWidth: 8 * unit, lineCap: .round))

        // The trigger finger: out, then curling down at the knuckle.
        let angle = Angle.degrees(-8 + c * 68)
        let knuckle = point(14, -14)
        var finger = hand
        finger.translateBy(x: knuckle.x, y: knuckle.y)
        finger.rotate(by: angle)
        finger.translateBy(x: -knuckle.x, y: -knuckle.y)
        var f = Path()
        f.move(to: knuckle)
        f.addLine(to: CGPoint(x: knuckle.x + 36 * unit, y: knuckle.y))
        finger.stroke(f, with: .color(skin), style: StrokeStyle(lineWidth: 8 * unit, lineCap: .round))

        // The muzzle flash, from the fingertip, only just after the pull.
        if t > 0.43 && t < 0.58 {
            let k = 1 - (t - 0.43) / 0.15
            let tip = CGPoint(x: knuckle.x + 40 * unit, y: knuckle.y - 4 * unit)
            for i in 0..<7 {
                let a = Double(i) / 7 * 2 * .pi
                var ray = Path()
                ray.move(to: CGPoint(x: tip.x + cos(a) * 3 * unit, y: tip.y + sin(a) * 3 * unit))
                ray.addLine(to: CGPoint(x: tip.x + cos(a) * (6 + 9 * k) * unit, y: tip.y + sin(a) * (6 + 9 * k) * unit))
                context.stroke(ray, with: .color(.yellow.opacity(k)),
                               style: StrokeStyle(lineWidth: 2.2 * unit, lineCap: .round))
            }
            context.fill(Path(ellipseIn: CGRect(x: tip.x - 5 * unit * k, y: tip.y - 5 * unit * k,
                                                width: 10 * unit * k, height: 10 * unit * k)),
                         with: .color(.white.opacity(k)))
        }
    }
}

/// A found file at its place in a page: the picture or clip.
struct PreviewMediaFile: View {
    let found: PreviewAssets.Found
    var body: some View {
        switch found {
        case .image(let url): AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
        case .video(let url): LoopingVideo(url: url)
        }
    }
}
