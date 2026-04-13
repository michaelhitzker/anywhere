//
//  ContentView.swift
//  anywhere-bridge
//
//  Created by Michael on 10.04.26.
//

import SwiftUI

struct ContentView: View {
    let store: CompanionStore
    @SceneStorage("content.selection") private var selectedSectionRawValue = CompanionSection.overview.rawValue

    private var currentSection: CompanionSection {
        CompanionSection(rawValue: selectedSectionRawValue) ?? .overview
    }

    private var selection: Binding<CompanionSection?> {
        Binding(
            get: { currentSection },
            set: { newValue in
                selectedSectionRawValue = newValue?.rawValue ?? CompanionSection.overview.rawValue
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            CompanionSidebar(selection: selection, store: store)
        } detail: {
            CompanionDetailView(section: currentSection, store: store)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            CompanionToolbar(store: store)
        }
        .frame(minWidth: 980, minHeight: 760)
        .task {
            store.start()
        }
    }
}

#Preview {
    ContentView(store: CompanionStore())
}

private struct CompanionToolbar: ToolbarContent {
    let store: CompanionStore

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                store.refreshNow()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Button {
                store.chooseRepoRoot()
            } label: {
                Label("Choose Repo Root", systemImage: "folder")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if store.daemonState == .online || store.daemonState == .starting {
                Button {
                    store.stopDaemon()
                } label: {
                    Label("Stop Daemon", systemImage: "stop.circle")
                }
            } else {
                Button {
                    store.launchDaemon()
                } label: {
                    Label("Launch Daemon", systemImage: "play.circle.fill")
                }
            }

            Button {
                store.openLocalBridge()
            } label: {
                Label("Open Local API", systemImage: "safari")
            }

            Button {
                store.openMobileAddress()
            } label: {
                Label("Open Mobile Address", systemImage: "iphone")
            }
            .disabled(store.mobileBridgeURL == nil)
        }
    }
}
