//
//  ConfigPage.swift
//  Wado's MAA
//
//  日常配置：日常 / 高级分段。每项改了就写（`ConfigFieldRow`，底层逐项 `config set`），写完可撤销。
//

import SwiftUI

struct ConfigPage: View {
    @Environment(RemoteStore.self) private var store
    @AppStorage("WMConfigTab") private var tab = "daily"

    private var groups: [String] {
        let all = (store.config?.groups ?? []).filter { $0 != "场次" }  // copy-guard: ignore（maa_settings 的分组键）
        return tab == "daily" ? all.filter { $0 == "日常" } : all.filter { $0 != "日常" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "日常配置", caption: latestMeta) {
                    Picker("分组", selection: $tab) {
                        Text("日常").tag("daily")
                        Text("高级").tag("adv")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("日常：每天会碰到的；高级：自动定关、抄作业、森空岛、运行环境")
                }
                RemoteNotices()
                VStack(alignment: .leading, spacing: 0) {
                    if store.config == nil {
                        Text("还没读到配置").foregroundStyle(WM.f2)
                    }
                    ForEach(groups, id: \.self) { group in
                        FormGroup(title: group) {
                            ForEach((store.config?.fields ?? []).filter { $0.group == group }) { field in
                                ConfigFieldControl(field: field)
                            }
                        }
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .disabled(store.readOnly)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 40)
        }
    }

    private var latestMeta: String? {
        store.config?.meta.values.max { ($0.updatedAt ?? "") < ($1.updatedAt ?? "") }?.text
    }
}
