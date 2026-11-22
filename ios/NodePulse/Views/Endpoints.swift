import SwiftUI

struct EndpointList: View {
    @Bindable var store: MonitorStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Endpoint?
    @State private var adding = false
    @State private var error: String?
    var body: some View {
        List {
            if store.endpoints.isEmpty { ContentUnavailableView("尚未添加接入点", systemImage: "network", description: Text("通过直连 TCP 或 HTTPS 连接探针")) }
            ForEach(store.endpoints) { endpoint in
                Button { editing = endpoint } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { OnlineStatus(online: store.statuses[endpoint.id]?.lastSuccess != nil && store.statuses[endpoint.id]?.error == nil); Text(endpoint.name).font(.headline).foregroundStyle(.primary); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                        if let status = store.statuses[endpoint.id] {
                            if let error = status.error { Text(error).font(.caption).foregroundStyle(.orange) }
                            if status.droppedBlobs > 0 { Text("已忽略 \(status.droppedBlobs) 个校验失败的密文").font(.caption).foregroundStyle(.orange) }
                            HStack {
                                if let latency = status.latency { Text("\(Int(latency)) 毫秒") }
                                if let date = status.lastSuccess { Text("更新于 \(date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))") }
                            }.font(.caption).foregroundStyle(.secondary)
                        } else { Text("等待首次连接").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 6)
                }.swipeActions { Button("删除", role: .destructive) { do { try store.delete(endpoint) } catch { self.error = error.localizedDescription } } }
            }
            if !store.hiddenNodes.isEmpty {
                Section {
                    ForEach(store.hiddenNodes) { node in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(node.name.isEmpty ? "未命名节点" : node.name)
                                Text(store.endpoints.first(where: { $0.id == node.endpointID })?.name ?? "演示")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("恢复") { store.restoreNode(node); Task { await store.refresh() } }
                                .buttonStyle(.borderless)
                        }
                    }
                } header: { Text("已隐藏的节点") } footer: { Text("恢复后将在下次成功刷新时重新显示，历史采样从零开始。") }
            }
        }.navigationTitle("接入点").toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("添加接入点") }
            ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
        }.sheet(item: $editing) { EndpointForm(store: store, existing: $0) }
            .sheet(isPresented: $adding) { AddEndpointView(store: store) }
            .alert("无法删除", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }
}

struct EndpointForm: View {
    static func swappedPort(_ port: String, from: Int, to: Int) -> String {
        let defaults = [0: "9000", 2: "9010"]
        guard let next = defaults[to], defaults[from] == nil || port == defaults[from] else { return port }
        return next
    }
    var store: MonitorStore
    var existing: Endpoint?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type = 0
    @State private var host = ""
    @State private var port = "9000"
    @State private var url = ""
    @State private var secret = ""
    @State private var groupSecret = ""
    @State private var reveal = false
    @State private var revealGroup = false
    @State private var generated = false
    @State private var testing = false
    @State private var result: String?
    @State private var success = false
    @State private var error: String?
    @State private var identity = UUID()
    private var isGroup: Bool { type >= 2 }
    private var isTCP: Bool { type == 0 || type == 2 }
    private var endpoint: Endpoint? {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !secret.isEmpty else { return nil }
        if isGroup && groupSecret.isEmpty { return nil }
        let kind: Endpoint.Kind
        if isTCP {
            guard !host.trimmingCharacters(in: .whitespaces).isEmpty, let port = UInt16(port), port > 0 else { return nil }
            kind = isGroup ? .groupTCP(host: host.trimmingCharacters(in: .whitespaces), port: port) : .direct(host: host.trimmingCharacters(in: .whitespaces), port: port)
        } else {
            guard (try? HTTPSClient.apiURL(url, path: isGroup ? "/api/relay" : "/api/nodes")) != nil else { return nil }
            kind = isGroup ? .groupHTTPS(urlString: url) : .https(urlString: url)
        }
        return Endpoint(id: identity, name: name, kind: kind)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称，例如：家庭路由器", text: $name)
                    Picker("类型", selection: Binding(get: { type }, set: { value in
                        port = Self.swappedPort(port, from: type, to: value)
                        type = value
                    })) {
                        Text("直连 TCP").tag(0); Text("HTTPS").tag(1)
                        Text("中继服务器（TCP）").tag(2); Text("中继服务器（HTTPS）").tag(3)
                    }
                }
                Section {
                    if isTCP {
                        TextField("主机名或 IP 地址", text: $host).keyboardType(.URL)
                        TextField("端口", text: $port).keyboardType(.numberPad)
                    } else { TextField("https://example.com", text: $url).keyboardType(.URL) }
                } header: { Text("连接地址") } footer: {
                    if isGroup { Text(isTCP ? "连接共享中继的 -S 端口。同组探针使用 -R 发布加密快照。" : "填写 HTTPS 基础地址或 /api/relay 完整路径，通过 POST 传输加密帧。") }
                    else { Text(type == 0 ? "直连使用端到端加密 TCP，对应探针的 -l 端口。无需配置 Web 服务器。" : "HTTPS 模式适用于放在 Nginx 反向代理后的探针。填写 HTTPS 基础地址或 /api/nodes 完整路径。") }
                }
                Section("认证") {
                    HStack {
                        if isGroup { Text("中继令牌").font(.subheadline) }
                        Group { if reveal { TextField(isGroup ? "输入中继令牌" : "密钥", text: $secret) } else { SecureField(isGroup ? "输入中继令牌" : "密钥", text: $secret) } }
                        Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }.accessibilityLabel(reveal ? "隐藏令牌或密钥" : "显示令牌或密钥")
                    }
                    if isGroup {
                        HStack {
                            Text("组密钥").font(.subheadline)
                            Group { if revealGroup { TextField("输入组密钥", text: $groupSecret) } else { SecureField("输入组密钥", text: $groupSecret) } }
                            Button { revealGroup.toggle() } label: { Image(systemName: revealGroup ? "eye.slash" : "eye") }.accessibilityLabel(revealGroup ? "隐藏组密钥" : "显示组密钥")
                        }
                        Button {
                            groupSecret = GroupCrypto.randomSecret()
                            UIPasteboard.general.setItems([["public.utf8-plain-text": groupSecret]],
                                                         options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                            generated = true
                        } label: { Label(generated ? "已生成并复制" : "生成随机组密钥", systemImage: generated ? "checkmark" : "key.fill") }
                    }
                }
                Section {
                    Button {
                        guard let endpoint else { return }
                        testing = true; result = nil
                        Task {
                            let response = await store.testConnection(endpoint, secret: secret, groupSecret: isGroup ? groupSecret : nil)
                            switch response { case .success(let count): success = true; result = "发现 \(count) 个节点"
                            case .failure(let error): success = false; result = error.localizedDescription }
                            testing = false
                        }
                    } label: { HStack { Text("测试连接"); Spacer(); if testing { ProgressView() } else { Image(systemName: "bolt.horizontal.circle") } } }.disabled(endpoint == nil || testing)
                    if let result { Label(result, systemImage: success ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(success ? .mint : .orange).font(.subheadline) }
                } footer: {
                    Text(isGroup ? "端到端加密：中继无法解密或伪造节点数据。组密钥只在你的设备上保存，不会发送给中继；请在探针上配置相同的组密钥。令牌与组密钥分别保存在钥匙串中。" : "密钥仅保存在此设备的钥匙串中，不会上传或写入普通偏好设置。")
                }
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
                .navigationTitle(existing == nil ? "添加探针" : "编辑接入点").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") {
                        guard let endpoint else { return }
                        do { try store.save(endpoint, secret: secret, groupSecret: isGroup ? groupSecret : nil); Task { await store.refresh() }; dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(endpoint == nil || testing) }
                }
                .onAppear {
                    guard let existing else { return }
                    identity = existing.id; name = existing.name
                    do {
                        secret = try store.secret(for: existing)
                        if existing.kind.isGroup { groupSecret = try store.groupSecret(for: existing) }
                    } catch { self.error = error.localizedDescription }
                    switch existing.kind { case .direct(let h, let p): host = h; port = String(p); type = 0
                    case .https(let u): url = u; type = 1
                    case .groupTCP(let h, let p): host = h; port = String(p); type = 2
                    case .groupHTTPS(let u): url = u; type = 3 }
                }
                .onChange(of: type) { _, value in
                    result = nil
                }
                .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
        }
    }
}

struct SettingsView: View {
    @Bindable var store: MonitorStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("监控") {
                    Picker("刷新间隔", selection: $store.refreshInterval) { ForEach([1.0, 2, 3, 5, 10], id: \.self) { Text("\(Int($0)) 秒").tag($0) } }
                    Toggle("演示模式", isOn: $store.demoMode)
                    NavigationLink("接入点") { EndpointList(store: store) }
                    NavigationLink("管理密钥") { AdminKeySettings() }
                }
                Section("关于") {
                    LabeledContent("版本", value: "0.1.0")
                    Link(destination: URL(string: "https://github.com/cestbon0309/NodePulse")!) { Label("项目源代码", systemImage: "chevron.left.forwardslash.chevron.right") }
                }
            }.navigationTitle("设置").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
