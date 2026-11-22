import SwiftUI

struct AddEndpointView: View {
    @Bindable var store: MonitorStore
    @Environment(\.dismiss) private var dismiss
    @State private var manual = false
    @State private var pairing = false
    @State private var relay = false
    @State private var scanning = false
    @State private var link = ""
    @State private var invite: PairInvite?
    @State private var activeInvite: PairInvite?
    @State private var queuedInvite: PairInvite?
    @State private var initialAdmin = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { scanning = true } label: { Label("扫码配对", systemImage: "qrcode.viewfinder").font(.headline).padding(.vertical, 8) }
                } footer: { Text("扫描服务器终端上的二维码，仅填写连接信息；仍须核对图案和数字。") }
                Section {
                    Button { relay = false; activeInvite = nil; initialAdmin = false; pairing = true } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("直连配对").font(.headline)
                                Text("核对图案与数字，安全获取探针密钥").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 10)
                        } icon: { Image(systemName: "qrcode.viewfinder").font(.title2).foregroundStyle(.mint) }
                    }.accessibilityIdentifier("direct-pairing")
                    Button { relay = true; activeInvite = nil; initialAdmin = false; pairing = true } label: { Label("中转配对", systemImage: "point.3.connected.trianglepath.dotted").padding(.vertical, 8) }
                } footer: { Text("先在服务器安装器中开启配对，或运行 npulse -P。只有双方确认一致后才会交换密钥。") }
                Section("粘贴配对链接") {
                    TextField("nodepulse://pair?…", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    Button("预览连接信息") { consume(link) }.disabled(link.isEmpty)
                }
                Section {
                    Button { manual = true } label: { Label("手动输入密钥", systemImage: "key.horizontal") }
                } footer: { Text("也可手动添加直连、HTTPS 或端到端中继接入点。") }
            }.navigationTitle("添加接入点")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .navigationDestination(isPresented: $pairing) { PairingView(store: store, relay: relay, invite: activeInvite, initialAdmin: initialAdmin, done: { dismiss() }) }
                .sheet(isPresented: $manual) { EndpointForm(store: store) }
                .sheet(isPresented: $scanning, onDismiss: { if let queuedInvite { invite = queuedInvite; self.queuedInvite = nil } }) {
                    PairScanner { text in
                        do { guard let url = URL(string: text) else { throw PairError.handshake }; queuedInvite = try PairInvite(url: url); scanning = false }
                        catch { self.error = "无法识别配对二维码，请使用服务器当前显示的 NodePulse 二维码。"; scanning = false }
                    }
                }
                .sheet(item: $invite) { value in
                    PairInviteSheet(invite: value) { admin in
                        activeInvite = value; initialAdmin = admin; relay = value.isRelay; invite = nil; pairing = true
                    }
                }
                .alert("无法打开配对链接", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
                .onChange(of: store.pairingURL) { _, value in if let value { consume(value.absoluteString); store.pairingURL = nil } }
                .task {
                    if let url = store.pairingURL { consume(url.absoluteString); store.pairingURL = nil }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-show-pair") { pairing = true }
                    #endif
                }
        }
    }
    private func consume(_ text: String) {
        guard !pairing else { error = "请先完成或取消当前配对，再打开新的配对链接。"; return }
        do { guard let url = URL(string: text) else { throw PairError.handshake }; invite = try PairInvite(url: url); link = "" }
        catch { self.error = "配对链接无效或版本不受支持。请重新扫描服务器当前的二维码。" }
    }
}

struct PairingView: View {
    @Bindable var store: MonitorStore
    var relay = false
    var invite: PairInvite?
    var initialAdmin = false
    let done: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var host = ""
    @State private var port = "9527"
    @State private var grantAdmin = false
    @State private var token = ""
    @State private var relayCode = ""
    @State private var session: PairSession?
    @State private var phase = 0
    @State private var work: Task<Void, Never>?
    @State private var error: String?
    @State private var savedName = ""
    @State private var adminUnavailable = false
    @State private var appeared = false
    private var validPort: UInt16? { guard let p = UInt16(port), p > 0 else { return nil }; return p }
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if phase == 0 || phase == 1 {
                    Image(systemName: "network.badge.shield.half.filled").font(.system(size: 52, weight: .light)).foregroundStyle(.mint).padding(.top, 24)
                    Text(relay ? "无需公网 IP，中转配对" : "与探针安全配对").font(.title2.bold())
                    if invite != nil { Label("已扫码 · 仍需核对图案", systemImage: "qrcode").font(.caption).foregroundStyle(.mint) }
                    VStack(alignment: .leading, spacing: 16) {
                        TextField("IP 地址或主机名", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).accessibilityIdentifier("pair-host")
                        Divider()
                        HStack { Text("端口"); Spacer(); TextField("9527", text: $port).keyboardType(.numberPad).multilineTextAlignment(.trailing).accessibilityIdentifier("pair-port") }
                        if relay {
                            Divider(); SecureField("中转密码（访问令牌）", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("配对码 XXXX-XXXX", text: $relayCode).textInputAutocapitalization(.characters).autocorrectionDisabled().font(.system(.body, design: .monospaced))
                                .onChange(of: relayCode) { _, value in let formatted = PairInvite.formattedCode(value); if formatted != value { relayCode = formatted } }
                            Text("仅支持 TCP 中转配对，不使用 HTTPS。").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(20).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 22)).disabled(phase == 1)
                    Text("请先开启服务器的临时配对窗口。连接后请对照本机终端显示的图案和数字，不要使用对方发来的截图。").font(.subheadline).foregroundStyle(.secondary)
                    Button(action: connect) {
                        HStack { if phase == 1 { ProgressView() }; Text(phase == 1 ? "正在连接…" : "连接探针") }.frame(maxWidth: .infinity).padding(10)
                    }.buttonStyle(.borderedProminent).tint(.mint).disabled(phase == 1 || host.trimmingCharacters(in: .whitespaces).isEmpty || validPort == nil || (relay && (token.isEmpty || relayCode.count != 9)))
                } else if phase == 2 || phase == 3, let session {
                    Label("核对安全图案", systemImage: "checkmark.shield").font(.title2.bold()).padding(.top, 12)
                    Text("与服务器终端上的图案和数字完全一致吗？").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    VStack(spacing: 20) {
                        Text(session.art.trimmingCharacters(in: .newlines)).font(.system(size: 19, weight: .medium, design: .monospaced)).lineSpacing(2).fixedSize().foregroundStyle(.mint)
                            .accessibilityLabel("安全图案").accessibilityValue(session.art)
                        Text(session.code).font(.system(size: 42, weight: .semibold, design: .monospaced)).tracking(4).accessibilityIdentifier("pair-code")
                    }.frame(maxWidth: .infinity).padding(.vertical, 26)
                        .background(.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 28))
                        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.mint.opacity(0.25)))
                        .scaleEffect(appeared ? 1 : 0.94).opacity(appeared ? 1 : 0)
                        .onAppear { withAnimation(reduceMotion ? nil : .spring(duration: 0.5)) { appeared = true } }
                    if phase == 2 {
                        Toggle("同时授权本机管理", isOn: $grantAdmin).tint(.mint)
                        Text("管理授权可控制文件、终端和电源，可能拥有 root 权限；仅完整构建支持。请在 30 秒内确认。").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 16) {
                            Button("不一致", role: .destructive) { confirm(false) }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                            Button("一致") { confirm(true) }.buttonStyle(.borderedProminent).tint(.mint).frame(maxWidth: .infinity).accessibilityIdentifier("pair-confirm")
                        }.controlSize(.large)
                    } else {
                        ProgressView("等待服务器确认…").padding()
                        Text("请在服务器终端核对后输入 y 并回车。密钥仅在双方同意后传输。").font(.caption).foregroundStyle(.secondary)
                    }
                } else if phase == 4 {
                    Spacer(minLength: 60)
                    Image(systemName: "checkmark.shield.fill").font(.system(size: 84)).foregroundStyle(.mint.gradient).symbolEffect(.bounce, value: phase)
                    Text("配对成功").font(.largeTitle.bold()).accessibilityIdentifier("pair-success")
                    Text(savedName).font(.title3).foregroundStyle(.secondary)
                    Text("探针已添加，密钥已安全存入钥匙串。\n服务器退出配对并启动正常服务后即可监控。").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    if adminUnavailable { Text("当前为 lite 构建，未授予管理权限。需要管理时请先升级完整构建后重新配对。").font(.callout).foregroundStyle(.orange) }
                    Button("完成", action: done).buttonStyle(.borderedProminent).tint(.mint).controlSize(.large)
                }
            }.padding(24).frame(maxWidth: 520).frame(maxWidth: .infinity)
        }.navigationTitle(relay ? "中转配对" : "直连配对").navigationBarTitleDisplayMode(.inline)
            .onDisappear { work?.cancel(); session?.close() }
            .alert("配对未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
            .task {
                grantAdmin = initialAdmin
                if relay { port = "9010" }
                if let invite { host = invite.host; port = String(invite.port); token = invite.token ?? ""; relayCode = invite.code ?? ""; connect() }
                #if DEBUG
                host = UserDefaults.standard.string(forKey: "pair-host") ?? host
                port = UserDefaults.standard.string(forKey: "pair-port") ?? port
                #endif
            }
    }
    private func connect() {
        guard let port = validPort else { return }
        phase = 1
        host = host.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        work = Task {
            do {
                let connected = try await PairSession.connect(host: host, port: port, relayToken: relay ? token : nil, code: relay ? relayCode : nil, psk: invite?.psk)
                guard !Task.isCancelled else { connected.close(); return }
                session = connected; appeared = false; phase = 2
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; phase = 0 } }
        }
    }
    private func confirm(_ accepted: Bool) {
        guard let session else { return }
        phase = 3
        work = Task {
            do {
                var admin: Data?
                if accepted && grantAdmin {
                    try await AdminIdentity.authorize()
                    admin = try (AdminIdentity.load() ?? AdminIdentity.generate()).publicKey.rawRepresentation
                }
                let result = try await session.confirm(accepted, name: UIDevice.current.name, adminKey: admin)
                try Task.checkCancellation()
                let endpoint: Endpoint
                if relay {
                    guard result.mode == "relay", let group = result.group else { throw PairError.handshake }
                    let match = store.endpoints.first { value in
                        guard case .groupTCP(let h, let p) = value.kind else { return false }
                        return h.lowercased() == host.lowercased() && p == validPort && (try? store.groupSecret(for: value)) == group
                    }
                    endpoint = match ?? Endpoint(name: result.name, kind: .groupTCP(host: host, port: validPort!))
                    try store.save(endpoint, secret: token, groupSecret: group)
                } else {
                    guard result.mode == nil, let key = result.key, let port = result.port else { throw PairError.handshake }
                    endpoint = Endpoint(name: result.name, kind: .direct(host: host, port: port))
                    try store.save(endpoint, secret: key)
                }
                store.demoMode = false; savedName = result.name; adminUnavailable = grantAdmin && !result.admin
                withAnimation(reduceMotion ? nil : .spring(duration: 0.5)) { phase = 4 }
            } catch {
                session.close()
                if !Task.isCancelled { self.error = accepted ? error.localizedDescription : "图案或数字不一致，已取消配对，未保存任何密钥。"; phase = 0; self.session = nil }
            }
        }
    }
}
