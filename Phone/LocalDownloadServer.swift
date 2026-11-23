import Foundation
import Network
import Security
import SwiftUI
import Darwin

enum LocalDownloadError: LocalizedError {
    case wifi, identity, unavailable
    var errorDescription: String? {
        switch self {
        case .wifi: "请先将 iPhone 和 Mac 连接到同一 Wi-Fi。"
        case .identity: "无法生成临时 HTTPS 身份，请重试。"
        case .unavailable: "下载服务已关闭或录音已不可用。"
        }
    }
}

@MainActor
final class LocalDownloadServer: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var fingerprint = ""
    @Published private(set) var status = "下载服务未开启"
    @Published private(set) var expiresAt: Date?
    @Published private(set) var running = false
    private let store: JournalStore
    private let queue = DispatchQueue(label: "journal.local-download")
    private var listener: NWListener?
    private var monitor: NWPathMonitor?
    private var connections: [UUID: NWConnection] = [:]
    private var expiryTask: Task<Void, Never>?
    private var lease: LocalAccessLease?
    private var token = ""
    private var host = ""
    private var identity: LocalTLSIdentity?
    private var tickets: [String: (id: UUID, deadline: TimeInterval)] = [:]
    private var session = UUID()
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(store: JournalStore) { self.store = store }

    func start(minutes: Int) throws {
        guard let address = Self.wifiAddress() else { throw LocalDownloadError.wifi }
        try begin(address: address, timeout: Double(StoragePolicy.idleMinutes(minutes)) * 60, wifi: true)
    }

    private func begin(address: String, timeout: TimeInterval, wifi: Bool) throws {
        stop(reason: "正在准备安全连接")
        let identity = try LocalTLSIdentity(address: address)
        let token = try LocalTLSIdentity.randomToken()
        let tls = NWProtocolTLS.Options()
        guard let secured = sec_identity_create(identity.identity) else { throw LocalDownloadError.identity }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secured)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        if wifi { parameters.requiredInterfaceType = .wifi }
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: .any)
        let listener = try NWListener(using: parameters)
        self.identity = identity
        self.token = token
        self.listener = listener
        running = true
        fingerprint = identity.fingerprint
        let current = session
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.session == current else { return }
                switch state {
                case .ready:
                    guard let port = self.listener?.port else { self.stop(reason: "无法读取下载端口"); return }
                    self.host = "\(address):\(port.rawValue)"
                    self.url = URL(string: "https://\(self.host)/#\(token)")
                    self.lease = LocalAccessLease(timeout: timeout, now: self.now)
                    self.expiresAt = .now.addingTimeInterval(timeout)
                    self.status = "保持此 App 在前台，Mac 可下载手机已接收的录音"
                    self.startExpiryTimer(session: current)
                case .failed(let error): self.stop(reason: error.localizedDescription)
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.session == current, self.connections.count < 8 else { connection.cancel(); return }
                let id = UUID()
                self.connections[id] = connection
                connection.start(queue: self.queue)
                Task { await self.serve(connection, id: id, session: current) }
            }
        }
        listener.start(queue: queue)
        if wifi {
            let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
            self.monitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor in
                    guard let self, self.session == current else { return }
                    if path.status != .satisfied || Self.wifiAddress() != address {
                        self.stop(reason: "Wi-Fi 连接已变化，下载服务已关闭")
                    }
                }
            }
            monitor.start(queue: queue)
        }
    }

    func stop(reason: String = "下载服务已关闭") {
        session = UUID()
        listener?.cancel(); listener = nil
        monitor?.cancel(); monitor = nil
        expiryTask?.cancel(); expiryTask = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        tickets.removeAll()
        identity = nil; token = ""; host = ""; lease = nil
        url = nil; expiresAt = nil; fingerprint = ""; running = false
        status = reason
    }

    private func startExpiryTimer(session: UUID) {
        expiryTask = Task { [weak self] in
            while let self, self.session == session, let lease = self.lease {
                let seconds = lease.deadline - self.now
                if seconds <= 0 { self.stop(reason: "空闲时间已到，下载服务已自动关闭"); return }
                do { try await Task.sleep(for: .seconds(seconds)) }
                catch { return }
            }
        }
    }

    private func active(_ session: UUID) -> Bool {
        guard self.session == session, let lease else { return false }
        if lease.expired(at: now) { stop(reason: "空闲时间已到，下载服务已自动关闭"); return false }
        return true
    }
    @discardableResult
    private func touch(_ session: UUID) -> Bool {
        guard active(session), lease?.touch(at: now) == true else { return false }
        expiresAt = .now.addingTimeInterval(lease!.timeout)
        return true
    }

    private func serve(_ connection: NWConnection, id: UUID, session: UUID) async {
        // Bound partial headers and stalled TLS handshakes independently of the session lease.
        let headerDeadline = Task {
            do { try await Task.sleep(for: .seconds(10)); connection.cancel() } catch {}
        }
        defer { headerDeadline.cancel(); connection.cancel(); connections.removeValue(forKey: id) }
        do {
            var data = Data()
            while !data.suffix(4).elementsEqual([13, 10, 13, 10]) {
                let chunk = try await receive(connection)
                guard !chunk.isEmpty, data.count + chunk.count <= 16_384 else { return }
                data.append(chunk)
            }
            headerDeadline.cancel()
            guard active(session) else { return }
            guard let request = LocalHTTPRequest(data, host: host) else {
                try await respond(connection, code: 400, body: Data("Bad request".utf8)); return
            }
            if request.path == "/" {
                try await respond(connection, code: 200, body: Data(Self.page.utf8), type: "text/html; charset=utf-8")
                return
            }
            if request.path.hasPrefix("/download/") {
                let key = String(request.path.dropFirst("/download/".count))
                guard let ticket = tickets.removeValue(forKey: key), ticket.deadline > now else {
                    try await respond(connection, code: 403, body: Data()); return
                }
                try await download(ticket.id, to: connection, session: session)
                return
            }
            guard request.authorized(token: token) else {
                try await respond(connection, code: 401, body: Data()); return
            }
            if request.path == "/api/metadata" {
                let data = try Export.metadata(store)
                guard touch(session) else { return }
                try await respond(connection, code: 200, body: data, type: "application/json")
            } else if request.path == "/api/recordings" {
                let entries = try store.pendingRecordings().filter(\.isPlayable)
                let rows = try entries.filter { FileManager.default.fileExists(atPath: try store.audio($0.id).path) }
                    .map { ["id": $0.id.uuidString, "title": $0.title, "duration": durationText($0.duration)] }
                guard touch(session) else { return }
                try await respond(connection, code: 200, body: JSONSerialization.data(withJSONObject: rows), type: "application/json")
            } else if request.path.hasPrefix("/api/ticket/"),
                      let id = UUID(uuidString: String(request.path.dropFirst("/api/ticket/".count))),
                      let entry = try? store.recording(id), entry.isPlayable,
                      FileManager.default.fileExists(atPath: try store.audio(id).path) {
                tickets = tickets.filter { $0.value.deadline > now }
                guard tickets.count < 128 else { try await respond(connection, code: 429, body: Data()); return }
                let ticket = try LocalTLSIdentity.randomToken()
                tickets[ticket] = (id, now + 30)
                guard touch(session) else { return }
                try await respond(connection, code: 200, body: JSONSerialization.data(withJSONObject: ["path": "/download/\(ticket)"]),
                                  type: "application/json")
            } else { try await respond(connection, code: 404, body: Data()) }
        } catch {
            // Connection errors must not expose filenames, access tokens or private metadata.
        }
    }

    private func download(_ id: UUID, to connection: NWConnection, session: UUID) async throws {
        guard let entry = try? store.recording(id), entry.isPlayable else {
            try await respond(connection, code: 404, body: Data()); return
        }
        let audio = try store.audio(id)
        let handle = try FileHandle(forReadingFrom: audio)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard touch(session) else { return }
        try await send(connection, data: Data(headers(code: 200, size: size, type: "audio/mp4",
            extra: "Content-Disposition: attachment; filename=\"WristJournal-\(id.uuidString).m4a\"\r\n").utf8))
        while let bytes = try handle.read(upToCount: 65_536), !bytes.isEmpty {
            guard active(session) else { return }
            try await send(connection, data: bytes)
            guard touch(session) else { return }
        }
    }

    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }
    private func send(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func respond(_ connection: NWConnection, code: Int, body: Data, type: String = "text/plain") async throws {
        try await send(connection, data: Data(headers(code: code, size: UInt64(body.count), type: type).utf8) + body)
    }
    private func headers(code: Int, size: UInt64, type: String, extra: String = "") -> String {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 429: "Too Many Requests"][code] ?? "Error"
        return "HTTP/1.1 \(code) \(reason)\r\nContent-Length: \(size)\r\nContent-Type: \(type)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n\(extra)\r\n"
    }

    private static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var current = list
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard String(cString: item.pointee.ifa_name) == "en0",
                  let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: buffer)
            }
        }
        return nil
    }

    #if DEBUG
    func startSimulation(timeout: TimeInterval) throws { try begin(address: "127.0.0.1", timeout: timeout, wifi: false) }
    func simulationCertificate() -> Data? { identity?.certificate }
    #endif

    private static let page = """
    <!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>恩名手记 · 临时下载</title><style>
    body{font:17px system-ui;color:#173932;background:#f2f7f5;margin:40px auto;padding:24px;max-width:760px}
    h1{font-size:32px}p{line-height:1.7}button{font:inherit;border:0;border-radius:8px;padding:10px 18px;background:#176552;color:white;cursor:pointer}
    li{display:flex;gap:16px;align-items:center;justify-content:space-between;background:white;padding:18px;margin:12px 0;border-radius:12px}
    ul{padding:0}small{display:block;color:#58746b}#status{color:#58746b}
    </style><h1>恩名手记 · 临时下载</h1><p>录音由 iPhone 临时提供。下载不会删除原音。保持手机 App 在前台；空闲到期后连接会关闭。</p>
    <button id="refresh">读取录音列表</button> <button id="metadata">下载元数据与已有报告</button>
    <p>元数据含录音时间、时区、地点、已有运动窗口与健康报告，缺少的音频会标明。原音请逐段下载。</p>
    <p id="status">请使用手机显示的完整网址连接。</p><ul id="list"></ul>
    <script>
    const token=location.hash.slice(1);history.replaceState(null,'','/');
    const status=document.getElementById('status'),list=document.getElementById('list');
    async function api(path){const r=await fetch(path,{headers:{Authorization:'Bearer '+token},cache:'no-store'});if(!r.ok)throw Error('连接已关闭或访问凭证无效，请回到 iPhone 重新开启。');return r.json()}
    async function refresh(){try{const rows=await api('/api/recordings');list.replaceChildren();status.textContent=rows.length?'可下载 '+rows.length+' 段录音':'暂无本地原音，请先在手机同步。';
    rows.forEach(row=>{const li=document.createElement('li'),label=document.createElement('span'),small=document.createElement('small'),button=document.createElement('button');
    label.textContent=row.title;small.textContent=row.duration;label.append(small);button.textContent='下载';
    button.onclick=async()=>{try{const ticket=await api('/api/ticket/'+encodeURIComponent(row.id));const a=document.createElement('a');a.href=ticket.path;a.download='';document.body.append(a);a.click();a.remove();status.textContent='下载已开始';}catch(e){status.textContent=e.message}};
    li.append(label,button);list.append(li)})}catch(e){status.textContent=e.message}}
    document.getElementById('refresh').onclick=refresh;if(token)refresh();
    document.getElementById('metadata').onclick=async()=>{try{
    const data=await api('/api/metadata'),url=URL.createObjectURL(new Blob([JSON.stringify(data,null,2)],{type:'application/json'}));
    const a=document.createElement('a');a.href=url;a.download='WristJournal-metadata.json';document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);
    status.textContent='元数据已导出，原音保持不变';}catch(e){status.textContent=e.message}};
    </script></html>
    """
}
