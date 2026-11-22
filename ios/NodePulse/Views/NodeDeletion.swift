import SwiftUI

private struct NodeDeletion: ViewModifier {
    var store: MonitorStore
    @Binding var node: NodeItem?
    var onDelete: () -> Void
    @State private var error: String?

    func body(content: Content) -> some View {
        content.confirmationDialog("删除节点？", isPresented: Binding(
            get: { node != nil }, set: { if !$0 { node = nil } }
        ), titleVisibility: .visible, presenting: node) { item in
            Button("删除节点", role: .destructive) { remove(item, endpoint: false) }
            if store.removableEndpoint(for: item) != nil {
                Button("同时删除接入点和密钥", role: .destructive) { remove(item, endpoint: true) }
            }
            Button("取消", role: .cancel) { node = nil }
        } message: { item in
            Text("将从仪表盘移除「\(item.snapshot.name)」及其历史，并持续隐藏。可在设置 → 接入点中恢复。不会删除服务器上的数据。")
        }
        .alert("无法删除", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func remove(_ item: NodeItem, endpoint: Bool) {
        do { try store.deleteNode(item, removeEndpoint: endpoint); onDelete() }
        catch { self.error = error.localizedDescription }
    }
}

extension View {
    func nodeDeletion(store: MonitorStore, node: Binding<NodeItem?>, onDelete: @escaping () -> Void = {}) -> some View {
        modifier(NodeDeletion(store: store, node: node, onDelete: onDelete))
    }
}
