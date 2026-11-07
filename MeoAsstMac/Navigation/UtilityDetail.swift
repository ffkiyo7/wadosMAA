//
//  UtilityDetail.swift
//  MAA
//
//  Created by hguandl on 19/4/2023.
//

import SwiftUI

struct UtilityDetail: View {
    let entry: UtilityEntry?
    @State private var showInfo = true

    @ViewBuilder var content: some View {
        if showInfo {
            switch entry {
            case .recruit:
                RecruitView()
            case .depot:
                DepotView()
            case .oper:
                OperBoxView()
            case .video:
                VideoRecogView()
            case .gacha:
                GachaView()
            case .minigame:
                MiniGameView()
            case .maatools:
                MaaToolsView()
            case .none:
                Text("请选择工具项目")
            }
        } else {
            LogView()
        }
    }

    var body: some View {
        // 内容不够高时（分辨率指南、寻访提示）靠上排，不要被居中到窗口中下部。
        // 标题由外层的 navigationTitle 给，这里不再在工具栏里放第二份。
        VStack {
            content
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItem {
                Picker("工具介绍", selection: $showInfo) {
                    Label("info", systemImage: "info")
                        .tag(true)
                        .help("工具介绍")
                    Label("日志", systemImage: "note.text")
                        .tag(false)
                        .help("运行日志")
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

struct UtilityDetail_Previews: PreviewProvider {
    static var previews: some View {
        UtilityDetail(entry: .recruit)
            .environmentObject(MAAViewModel())
    }
}
