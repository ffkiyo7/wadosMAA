//
//  CopilotView.swift
//  MAA
//
//  Created by hguandl on 19/4/2023.
//

import SwiftUI

struct CopilotView: View {
    let context: CopilotContext

    var body: some View {
        @Bindable var context = context
        if context.category == .list {
            if let set = context.copilotSet {
                switch context.content {
                case .copilot(_, let kind, let copilot):
                    CopilotConfigView(kind: kind, config: $context.config) {
                        CopilotDescriptionView(pilot: copilot)
                    }
                case .invalid:
                    Text("文件格式错误")
                case .pending:
                    ProgressView().controlSize(.small)
                default:
                    CopilotConfigView(kind: set.kind, config: $context.config) {
                        CopilotSetDescriptionView(set: set.data)
                    }
                }
            } else {
                Text("请选择作业项目")
            }
        } else {
            switch context.content {
            case .copilot(_, let kind, let copilot):
                CopilotConfigView(kind: kind, config: $context.config) {
                    CopilotDescriptionView(pilot: copilot)
                }
            case .set(let url, let set):
                Button("激活此作业集") {
                    Task {
                        await context.updateSet(at: url, set: set)
                        context.category = .list
                    }
                }
                .buttonStyle(.borderedProminent)
                Divider().padding(.vertical)
                CopilotSetDescriptionView(set: set)
            case .directory, nil:
                Text("请选择作业项目")
            case .invalid:
                Text("文件格式错误")
            case .pending:
                ProgressView().controlSize(.small)
            }
        }
    }
}

// MARK: - Copilot Config

private struct CopilotConfigView<D: View>: View {
    let kind: MAACopilot.Kind

    @Binding var config: CopilotConfiguration

    let description: D

    init(kind: MAACopilot.Kind, config: Binding<CopilotConfiguration>, @ViewBuilder description: () -> D) {
        self.kind = kind
        self._config = config
        self.description = description()
    }

    var body: some View {
        VStack(spacing: 12) {
            switch kind {
            case .regular:
                RegularCopilotConfigView(config: $config)
                Divider()
            case .sss:
                SSSCopilotConfigView(config: $config)
                Divider()
            case .paradox:
                EmptyView()
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    description
                }
            }
        }
        .padding(.top)
        .animation(.default, value: config.formation)
    }
}

private struct RegularCopilotConfigView: View {
    @Binding var config: CopilotConfiguration

    var body: some View {
        HStack {
            Toggle("自动编队", isOn: $config.formation)
        }
        if config.formation {
            HStack {
                Picker("编队栏位", selection: $config.formation_index) {
                    Text("当前").tag(0)
                    ForEach(1...4, id: \.self) { index in
                        Text("\(index)").tag(index)
                    }
                }
                .pickerStyle(.menu)
                Toggle("补充低信赖干员", isOn: $config.add_trust)
            }
            // 吃药、忽视练度、助战都不提供（K11）。
        }
        SSSCopilotConfigView(config: $config)
    }
}

private struct SSSCopilotConfigView: View {
    @Binding var config: CopilotConfiguration

    var body: some View {
        HStack {
            Text("循环次数")
            TextField("1", value: $config.loop_times, format: .number)
        }
        .frame(maxWidth: 130)
    }
}

// MARK: - Copilot Document

private struct CopilotDescriptionView: View {
    let pilot: MAACopilot

    var body: some View {
        if let title = pilot.doc?.title {
            Text(title).font(.title2)
        }
        if let details = pilot.doc?.details {
            Text(details)
        }

        if let equipments = pilot.equipment {
            Text("装备：") + Text(equipments.joined(separator: ", "))
        }

        if let strategy = pilot.strategy {
            Text(strategy)
        }

        if pilot.opers.count > 0 {
            VStack {
                ForEach(pilot.opers, id: \.name) { oper in
                    Text(oper.description)
                }
            }
        }

        if let groups = pilot.groups {
            VStack {
                ForEach(groups, id: \.name) { group in
                    Text(group.name) + Text(verbatim: ": ")
                        + Text(group.opers.map(\.description).joined(separator: " / "))
                }
            }
        }

        if let toolmen = pilot.tool_men {
            Text(toolmen.sorted { $0.key < $1.key }.map { "\($1)\($0)" }.joined(separator: ", "))
        }
    }
}

private struct CopilotSetDescriptionView: View {
    let set: CopilotSetData

    var body: some View {
        Text(set.name).font(.title2)
        Text(set.description)
    }
}

#Preview("Regular Copilot Config") {
    let context = CopilotContext()
    let url = URL.bundledCopilotDirectory
        .appending(path: "OF-1_credit_fight")
        .appendingPathExtension("json")
    context.selection = .init(url: url, isRaid: nil)

    return VStack {
        CopilotView(context: context)
    }
}

#Preview("SSS Copilot Config") {
    let context = CopilotContext()
    let url = URL.bundledCopilotDirectory
        .appending(path: "old/")
        .appending(path: "约翰老妈新建地块_Mama_Johns_New_Plate/")
        .appending(path: "SSS_约翰老妈新建地块")
        .appendingPathExtension("json")
    context.selection = .init(url: url, isRaid: nil)

    return VStack {
        CopilotView(context: context)
    }
}
