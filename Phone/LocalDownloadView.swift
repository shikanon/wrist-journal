import SwiftUI

struct LocalDownloadView: View {
    @ObservedObject var journal: PhoneJournal
    @ObservedObject var server: LocalDownloadServer

    var body: some View {
        Form {
            Section {
                Text("将 iPhone 与 Mac 连到同一 Wi-Fi，先同步录音，再开启下载。下载期间请保持此 App 在前台。")
                Text("Apple Watch 无法运行此类网页服务，录音通过 iPhone 中转。")
                    .foregroundStyle(.secondary)
                Text("Mac 页面可下载原音，以及包含时间、时区、地点、已有运动数据和健康报告的 JSON 元数据。导出不会删除原音。")
                Button("先同步录音") { journal.syncRecordings() }
                if let status = journal.storageSyncStatus { Text(status).font(.footnote) }
            }
            Section {
                Stepper("空闲 \(StoragePolicy.idleMinutes(journal.dailySettings.localAccessMinutes)) 分钟后关闭",
                        value: Binding(get: { StoragePolicy.idleMinutes(journal.dailySettings.localAccessMinutes) },
                                       set: { journal.dailySettings.localAccessMinutes = $0 }), in: 1...60)
                    .disabled(server.running)
                if server.running {
                    Button("关闭下载服务", role: .destructive) { server.stop() }
                } else {
                    Button("开启安全下载") {
                        do { try server.start(minutes: StoragePolicy.idleMinutes(journal.dailySettings.localAccessMinutes)) }
                        catch { journal.message = error.localizedDescription }
                    }
                }
                Text(server.status).font(.footnote)
                if let expires = server.expiresAt {
                    LabeledContent("空闲截止时间", value: expires.formatted(date: .omitted, time: .standard))
                }
            }
            if let url = server.url {
                Section("Mac 连接网址") {
                    Text(url.absoluteString).font(.footnote.monospaced()).textSelection(.enabled)
                    ShareLink("传递连接网址", item: url)
                    Text("网址包含临时访问凭证，只交给自己的 Mac。每次开启都会更换。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("首次连接") {
                    Text("浏览器会提示证书由本机签发。查看证书的 SHA-256 指纹，核对下方内容一致后，仅为本次连接允许访问。")
                    Text(server.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Mac 临时下载")
    }
}
