//
//  AnywhereBridgeApp.swift
//  anywhere-bridge
//
//  Created by Michael on 10.04.26.
//

import SwiftUI

@main
struct AnywhereBridgeApp: App {
    private static let mainWindowID = "main-window"
    @State private var store = CompanionStore()

    var body: some Scene {
        WindowGroup("Anywhere Bridge", id: Self.mainWindowID) {
            ContentView(store: store)
        }
        .defaultSize(width: 1100, height: 780)
        .commands {
            CommandMenu("Companion") {
                Button("Refresh Status") {
                    store.refreshNow()
                }
                .keyboardShortcut("r")

                Button("Choose Repo Root") {
                    store.chooseRepoRoot()
                }

                Divider()

                if store.daemonState == .online || store.daemonState == .starting {
                    Button("Stop Daemon") {
                        store.stopDaemon()
                    }
                } else {
                    Button("Launch Daemon") {
                        store.launchDaemon()
                    }
                }

                Button("Open Local API") {
                    store.openLocalBridge()
                }

                Button("Open Mobile Address") {
                    store.openMobileAddress()
                }
                .disabled(store.mobileBridgeURL == nil)
            }
        }

        MenuBarExtra {
            CompanionMenuBarOverview(store: store, mainWindowID: Self.mainWindowID)
                .task {
                    store.start()
                }
        } label: {
            Label("Anywhere Bridge", systemImage: menuBarSymbolName)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbolName: String {
        switch store.daemonState {
        case .online:
            "bolt.horizontal.circle.fill"
        case .starting:
            "ellipsis.circle.fill"
        case .misconfigured:
            "exclamationmark.triangle.fill"
        case .offline:
            "bolt.horizontal.circle"
        }
    }
}
