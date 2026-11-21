//
//  SevenDial.swift
//  Wado's MAA (iOS)
//
//  七段步骤图（E1 / E3 / E12）。每段从内向外生长，正在跑的那段长到一半。
//

import SwiftUI
import WadosMAAShared

struct SevenDial: View {
    struct Segment: Equatable {
        let color: Color
        /// 0 = 空，1 = 满。
        let fill: Double
    }

    let segments: [Segment]
    var label: String?
    var accessibilityText: String?

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Canvas { context, size in
                    draw(in: &context, size: size)
                }
                if let label {
                    Text(label)
                        .font(.system(size: side * 0.15, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .frame(width: side * 0.32)
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText ?? label ?? "")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let scale = min(size.width, size.height) / 300
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let width = 36 * scale
        let inner = 72 * scale
        let outer = 122 * scale
        let count = max(segments.count, 1)
        for (index, segment) in segments.enumerated() {
            let angle = Double(index) / Double(count) * 2 * .pi
            let direction = CGVector(dx: sin(angle), dy: -cos(angle))
            let start = CGPoint(x: center.x + direction.dx * inner, y: center.y + direction.dy * inner)
            let end = CGPoint(x: center.x + direction.dx * outer, y: center.y + direction.dy * outer)
            var track = Path()
            track.move(to: start)
            track.addLine(to: end)
            let style = StrokeStyle(lineWidth: width, lineCap: .round)
            context.stroke(track, with: .color(Palette.ghost), style: style)
            guard segment.fill > 0 else { continue }
            let reach = inner + (outer - inner) * min(segment.fill, 1)
            var filled = Path()
            filled.move(to: start)
            filled.addLine(to: CGPoint(x: center.x + direction.dx * reach, y: center.y + direction.dy * reach))
            context.stroke(filled, with: .color(segment.color), style: style)
        }
    }
}

extension SevenDial.Segment {
    /// 按进度文件的步骤排七段；缺的步骤按没开始算。
    static func daily(_ steps: [RunProgressStep]) -> [SevenDial.Segment] {
        DailyStep.allCases.map { item in
            let state = steps.first { $0.key == item.rawValue }?.state ?? .pending
            switch state {
            case .done: return .init(color: item.color, fill: 1)
            case .running: return .init(color: item.color, fill: 0.5)
            case .failed: return .init(color: Palette.stop, fill: 1)
            case .pending, .skipped: return .init(color: item.color, fill: 0)
            }
        }
    }
}
