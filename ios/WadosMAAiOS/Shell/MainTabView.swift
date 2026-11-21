//
//  MainTabView.swift
//  Wado's MAA (iOS)
//

import SwiftUI

struct MainTabView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.selectedTab) {
            Tab("今天", systemImage: "sun.max", value: AppTab.today) {
                TodayTab()
            }
            Tab("抄作业", systemImage: "square.on.square", value: AppTab.copilot) {
                CopilotTab()
            }
            .badge(store.copilotRemaining)
            Tab("日常", systemImage: "calendar", value: AppTab.daily) {
                DailyTab()
            }
            Tab("设置", systemImage: "slider.horizontal.3", value: AppTab.settings) {
                SettingsTab()
            }
        }
        .tabViewBottomAccessory(isEnabled: store.activeRun != nil || (store.selectedTab == .today && store.hasData)) {
            RunAccessory()
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                ToastView(toast: toast)
                    .padding(.bottom, store.activeRun == nil ? 96 : 150)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: store.toast)
        .sheet(isPresented: $store.isRunSheetPresented) {
            RunSheet()
        }
        .sheet(isPresented: $store.isStartRunPresented) {
            StartRunSheet()
        }
        .sheet(isPresented: $store.isPairingPresented) {
            PairingFlow(isSheet: true)
        }
    }
}

struct ToastView: View {
    @Environment(AppStore.self) private var store
    let toast: AppToast

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            if let title = toast.actionTitle, let action = toast.action {
                Button(title) { store.perform(action) }
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 44)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
    }
}

struct SkeletonBlock: View {
    var height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Palette.card)
            .frame(height: height)
            .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.5]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.9)
            }
            .accessibilityHidden(true)
    }
}
