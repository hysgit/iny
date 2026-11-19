import SwiftUI

struct WirelessTransferView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var transfer = WirelessTransfer()
    var body: some View {
        Form {
            if let address = transfer.address {
                LabeledContent("地址") { Text(address.absoluteString).textSelection(.enabled) }
                LabeledContent("用户名", value: "iny")
                LabeledContent("密码") { Text(transfer.password).textSelection(.enabled) }
                Text("在同一 Wi-Fi 的电脑浏览器打开地址即可传输视频。保持此页打开。").foregroundStyle(.secondary)
                Button("停止传输", role: .destructive) { transfer.stop() }
            } else { Button("开启无线传输") { transfer.start() } }
            if let error = transfer.error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("无线传输")
        .task { transfer.imported = { url in await store.importFiles([url]) } }
        .onDisappear { transfer.stop() }
    }
}
