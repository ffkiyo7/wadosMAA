//
//  DailyTab.swift
//  Wado's MAA (iOS)
//
//  占位：日常设置在 F4。
//

import SwiftUI

struct DailyTab: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("日常", systemImage: "calendar")
                .connectionBanner()
                .navigationTitle("日常")
        }
    }
}
