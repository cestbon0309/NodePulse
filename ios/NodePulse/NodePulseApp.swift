import SwiftUI

@main
struct NodePulseApp: App {
    @State private var store = MonitorStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .onChange(of: phase, initial: true) { _, phase in
                    if phase == .active { store.start() } else { store.stop() }
                }
        }
    }
}

struct ContentView: View {
    @Bindable var store: MonitorStore
    var body: some View {
        NavigationStack {
            List {
                Toggle("演示模式", isOn: $store.demoMode)
                ForEach(store.nodes) { item in
                    VStack(alignment: .leading) {
                        Text(item.snapshot.name.isEmpty ? item.snapshot.hostname : item.snapshot.name)
                        Text("\(item.online ? "在线" : "离线") · \(item.snapshot.os) · CPU \(item.snapshot.cpuUsage, specifier: "%.1f")%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("NodePulse")
        }
    }
}
