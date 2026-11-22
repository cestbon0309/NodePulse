import CryptoKit
import SwiftUI

struct AdminTarget {
    let endpoint: Endpoint
    let node: NodeItem
    let secret: String
    let group: String?
    @MainActor init(store: MonitorStore, node: NodeItem) throws {
        guard let endpoint = store.endpoints.first(where: { $0.id == node.endpointID }), AdminSession.supports(endpoint.kind) else {
            throw AdminError.message("此接入点不支持管理")
        }
        self.endpoint = endpoint; self.node = node
        secret = try store.secret(for: endpoint)
        group = endpoint.kind.isGroup ? try store.groupSecret(for: endpoint) : nil
    }
    func connect() async throws -> AdminSession {
        try await AdminIdentity.authorize()
        guard let key = try AdminIdentity.load() else { throw AdminError.message("请先在设置 → 管理密钥中生成密钥，并将公钥配置到探针 -A") }
        return try await AdminSession.connect(endpoint: endpoint, node: node.snapshot.id, secret: secret, groupSecret: group, signing: key)
    }
}

#if DEBUG
struct AdminDebugLaunch: View {
    let store: MonitorStore
    @State private var destination: AdminDestination?
    @State private var node: NodeItem?
    @State private var error: String?
    var body: some View {
        Group {
            if let node, ProcessInfo.processInfo.arguments.contains("-admin-detail") { NavigationStack { NodeDetail(store: store, nodeKey: node.key) } }
            else if let destination {
                if destination.terminal { AdminTerminalScreen(target: destination.target, initial: destination.session) }
                else { AdminFilesScreen(target: destination.target, initial: destination.session) }
            } else if let error { Text(error).padding() }
            else { ProgressView("正在连接实时探针…") }
        }.task {
            do {
                await store.refresh()
                guard let item = store.nodes.first else { throw AdminError.message("未发现实时探针") }
                node = item
                if ProcessInfo.processInfo.arguments.contains("-admin-detail") { return }
                let target = try AdminTarget(store: store, node: item), session = try await target.connect()
                destination = AdminDestination(terminal: ProcessInfo.processInfo.arguments.contains("-admin-terminal"), target: target, session: session)
            } catch { self.error = error.localizedDescription }
        }
    }
}
#endif

struct AdminDestination: Identifiable {
    let id = UUID()
    let terminal: Bool
    let target: AdminTarget
    let session: AdminSession
}

struct NodeAdminSection: View {
    let store: MonitorStore
    let node: NodeItem
    @State private var destination: AdminDestination?
    @State private var busy = false
    @State private var error: String?
    @State private var power: String?
    @State private var confirmed = false
    @State private var message: String?
    var body: some View {
        if let endpoint = store.endpoints.first(where: { $0.id == node.endpointID }), AdminSession.supports(endpoint.kind) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Label("管理", systemImage: "slider.horizontal.3").font(.headline); Spacer(); if busy { ProgressView() } else { Image(systemName: "lock.shield").foregroundStyle(.teal) } }
                HStack(spacing: 12) {
                    action("终端", symbol: "terminal") { open(terminal: true) }
                    action("文件", symbol: "folder") { open(terminal: false) }
                    action("重启", symbol: "arrow.clockwise", destructive: true) { power = "reboot"; confirmed = true }
                    action("关机", symbol: "power", destructive: true) { power = "poweroff"; confirmed = true }
                }.disabled(busy)
                if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                Text("以探针用户权限执行 · 端到端加密").font(.caption2).foregroundStyle(.secondary)
            }.pulsePanel()
                .fullScreenCover(item: $destination) { item in
                    if item.terminal { AdminTerminalScreen(target: item.target, initial: item.session) }
                    else { AdminFilesScreen(target: item.target, initial: item.session) }
                }
                .confirmationDialog(power == "reboot" ? "重启此节点？" : "关闭此节点？", isPresented: $confirmed, titleVisibility: .visible) {
                    Button(power == "reboot" ? "确认重启" : "确认关机", role: .destructive) { performPower() }
                    Button("取消", role: .cancel) {}
                } message: { Text("\(node.snapshot.name) 的连接将中断。请确认已保存工作，关机后可能需要现场重新启动。") }
                .alert("电源操作", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("好") { message = nil } } message: { Text(message ?? "") }
        }
    }
    private func action(_ title: String, symbol: String, destructive: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 9) { Image(systemName: symbol).font(.title3); Text(title).font(.caption.weight(.medium)) }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background((destructive ? Color.orange : .teal).opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain).foregroundStyle(destructive ? .orange : .teal)
    }
    private func open(terminal: Bool) {
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let target = try AdminTarget(store: store, node: node)
                let session = try await target.connect()
                destination = AdminDestination(terminal: terminal, target: target, session: session)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func performPower() {
        guard let power else { return }
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let session = try await AdminTarget(store: store, node: node).connect()
                do { _ = try await session.request("power", ["action": power]); await session.close(); message = "探针已确认，正在\(power == "reboot" ? "重启" : "关机")…" }
                catch { await session.close(); throw error }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct AdminKeySettings: View {
    @AppStorage("adminBiometrics") private var biometrics = true
    @State private var publicKey = ""
    @State private var error: String?
    @State private var regenerate = false
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "key.horizontal.fill").font(.system(size: 30)).foregroundStyle(.teal).padding(.vertical, 6)
                    Text("你的管理身份").font(.title2.bold())
                    Text("独立的 Ed25519 签名密钥。私钥仅保存在此设备的钥匙串中，不会发送给探针或中继。").font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 8)
                if publicKey.isEmpty {
                    Button("生成管理密钥", systemImage: "plus.circle.fill") { generate() }
                } else {
                    Text(String(publicKey.prefix(32)) + "\n" + String(publicKey.suffix(32))).font(.caption.monospaced()).accessibilityLabel("管理公钥 \(publicKey)")
                    HStack {
                        Button("复制公钥", systemImage: "doc.on.doc") { UIPasteboard.general.string = publicKey }
                        Spacer()
                        ShareLink(item: publicKey) { Label("分享公钥", systemImage: "square.and.arrow.up") }
                    }.font(.subheadline)
                }
            }
            if !publicKey.isEmpty {
                Section("添加到探针") {
                    code("启动参数", text: "-A \(publicKey)")
                    code("配置文件", text: "admin_keys=\(publicKey)")
                }
            }
            Section {
                Toggle("管理操作需要 Face ID", isOn: Binding(get: { biometrics }, set: { value in
                    Task { do { try await AdminIdentity.authorize(); biometrics = value } catch { self.error = "身份验证未通过" } }
                }))
            } footer: { Text("打开终端、文件或执行电源操作前验证身份。无生物识别时使用设备密码；模拟器或未设置设备密码时跳过。") }
            if !publicKey.isEmpty {
                Section { Button("重新生成密钥", role: .destructive) { regenerate = true } } footer: { Text("重新生成后，所有探针都需要更新允许的公钥。私钥无法恢复或跨设备同步。") }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }.navigationTitle("管理密钥").navigationBarTitleDisplayMode(.inline)
            .task { do { publicKey = try AdminIdentity.load().map { GroupCrypto.hex($0.publicKey.rawRepresentation) } ?? "" } catch { self.error = error.localizedDescription } }
            .confirmationDialog("重新生成管理密钥？", isPresented: $regenerate, titleVisibility: .visible) {
                Button("替换旧密钥", role: .destructive) { generate() }; Button("取消", role: .cancel) {}
            } message: { Text("旧私钥将被永久替换。请随后更新探针上的 -A / admin_keys。") }
    }
    private func code(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.caption).foregroundStyle(.secondary); Spacer(); Button("复制") { UIPasteboard.general.string = text }.font(.caption) }
            ScrollView(.horizontal, showsIndicators: false) { Text(text).font(.caption.monospaced()).textSelection(.enabled).fixedSize() }
        }.padding(.vertical, 6)
    }
    private func generate() {
        Task { do { try await AdminIdentity.authorize(); publicKey = GroupCrypto.hex(try AdminIdentity.generate().publicKey.rawRepresentation); error = nil } catch { self.error = error.localizedDescription } }
    }
}
