//
//  WadosMAAApp.swift
//  Wado's MAA (iOS)
//

import SwiftUI

@main
struct WadosMAAApp: App {
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task { store.start() }
                .onOpenURL { store.open($0) }
                .onChange(of: scenePhase) { _, phase in
                    store.scenePhaseChanged(phase)
                }
        }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.needsPairing {
            PairingFlow()
        } else {
            MainTabView()
        }
    }
}
