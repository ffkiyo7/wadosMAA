//
//  CopilotTab.swift
//  Wado's MAA (iOS)
//
//  外壳阶段只读列出当期关卡，开打和选作业在 F3。
//

import SwiftUI
import WadosMAAShared

struct CopilotTab: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if let stages = store.copilotStages?.stages, !stages.isEmpty {
                    List(stages) { row in
                        LabeledContent(row.code ?? row.stage, value: row.statusText ?? "")
                    }
                } else if store.hasData {
                    ContentUnavailableView("没有开放的活动", systemImage: "square.on.square")
                } else if store.connection == .connecting {
                    ProgressView()
                } else {
                    Color.clear
                }
            }
            .connectionBanner()
            .navigationTitle("抄作业")
        }
    }
}
