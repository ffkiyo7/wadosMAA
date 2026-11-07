//
//  ContentView.swift
//  MAA
//
//  Created by hguandl on 13/4/2023.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: MAAViewModel

    var body: some View {
        // 重设计（定稿原型）：自绘边栏六页 + 状态条 + 日志检查器。原来的三栏页面嵌在「工具与更多」里。
        RedesignRoot()
            // K9：整个窗口一张背景图，侧栏和工具栏是系统的 Liquid Glass。
            .containerBackground(for: .window) {
                WindowBackground()
            }
        .modifier(LegacyImportPrompt())
        .task {
            // maa-remote 的状态文件一变就重读（K3）。
            RemoteStore.shared.startWatching()
            do {
                try await viewModel.initialize()
            } catch {
                viewModel.logError("初始化失败: \(error.localizedDescription)")
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(MAAViewModel())
    }
}
