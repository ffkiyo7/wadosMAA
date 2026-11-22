//
//  RunAccessory.swift
//  Wado's MAA (iOS)
//
//  Tab Bar 上方的悬浮运行胶囊：只在有一场在跑时出现，点开实时进度。
//

import SwiftUI
import WadosMAAShared

struct RunAccessory: View {
    @Environment(AppStore.self) private var store
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        if let run = store.activeRun {
            HStack(spacing: 4) {
            Button {
                store.isRunSheetPresented = true
            } label: {
                HStack(spacing: 10) {
                    RunMark(run: run)
                        .frame(width: 26, height: 26)
                    Text(run.statusText)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if placement != .inline, let eta = run.progress?.eta {
                        Text("约 \(BeijingTime.clock(eta))")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(Palette.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(run.title)，\(run.statusText)")
                if run.canStop {
                    Button {
                        store.isRunSheetPresented = true
                        store.requestStop()
                    } label: {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(.white)
                            .frame(width: 13, height: 13)
                            .frame(width: 36, height: 36)
                            .background(Palette.stop, in: .circle)
                            .frame(width: 44, height: 44)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canWrite)
                    .opacity(store.canWrite ? 1 : 0.4)
                    .accessibilityLabel("停止")
                }
            }
        } else {
            Button {
                store.isStartRunPresented = true
            } label: {
                Label("现在开一场", systemImage: "play.fill")
                    .scaledFont(size: 17, weight: .bold)
                    .foregroundStyle(Palette.blue)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!store.canWrite)
            .opacity(store.canWrite ? 1 : 0.4)
        }
    }
}

/// 日常用七段，抄作业用圆环，其他任务转圈。
struct RunMark: View {
    let run: ActiveRun

    var body: some View {
        switch run.kind {
        case .daily:
            SevenDial(segments: .daily(run.progress?.steps ?? []))
        case .copilot:
            CopilotRing(
                done: run.progress?.copilot?.done ?? 0,
                total: run.progress?.copilot?.total ?? 0,
                lineWidth: 4)
        case .other:
            ProgressView()
        }
    }
}

struct CopilotRing: View {
    let done: Int
    let total: Int
    var lineWidth: CGFloat = 10

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(Double(done) / Double(total), 1)
    }

    var body: some View {
        ZStack {
            Circle().stroke(Palette.ghost, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Palette.teal, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .animation(.snappy, value: fraction)
    }
}

extension Array where Element == SevenDial.Segment {
    static func daily(_ steps: [RunProgressStep]) -> [SevenDial.Segment] {
        SevenDial.Segment.daily(steps)
    }
}
