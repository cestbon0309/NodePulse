import SwiftUI

@main
struct NodePulseApp: App {
    @State private var store = MonitorStore()
    @Environment(\.scenePhase) private var phase
    init() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        let store = MonitorStore()
        if args.contains("-demo") { store.demoMode = true }
        if args.contains("-empty") {
            store.demoMode = false
            for endpoint in store.endpoints { try? store.delete(endpoint) }
        }
        if args.contains("-live") {
            store.demoMode = false
            for endpoint in store.endpoints { try? store.delete(endpoint) }
            try? store.save(Endpoint(name: "本机探针", kind: .direct(host: "127.0.0.1", port: 19090)), secret: "integration-secret")
        }
        if args.contains("-live-relay") {
            store.demoMode = false
            for endpoint in store.endpoints { try? store.delete(endpoint) }
            try? store.save(Endpoint(name: "本机端到端中继", kind: .groupTCP(host: "127.0.0.1", port: 19092)),
                            secret: "integration-relay-token", groupSecret: "integration-group-secret")
        }
        _store = State(initialValue: store)
        #endif
    }
    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
                .tint(Color("AccentColor"))
                .onChange(of: phase, initial: true) { _, phase in
                    if phase == .active { store.start() } else { store.stop() }
                }
        }
    }
}
