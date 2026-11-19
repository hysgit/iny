import Foundation
import AVFoundation
import Combine
import CryptoKit

struct DownloadRecord: Identifiable, Codable {
    var id: UUID { item.id }
    var item: MediaItem
    var state = "等待"
    var progress: Double = 0
    var error: String?
    var isHLS = false
}

@MainActor
final class BackgroundDownloads: NSObject, ObservableObject {
    static let shared = BackgroundDownloads()
    @Published private(set) var jobs: [UUID: DownloadRecord] = [:]
    private weak var store: AppStore?
    private var tasks: [UUID: URLSessionTask] = [:]
    private var lastSaved = Date.distantPast
    var completions: [String: () -> Void] = [:]
    private lazy var http: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "net.icycloud.iny.downloads")
        configuration.sessionSendsLaunchEvents = true; configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private lazy var hls: AVAssetDownloadURLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "net.icycloud.iny.hls")
        configuration.sessionSendsLaunchEvents = true
        return AVAssetDownloadURLSession(configuration: configuration, assetDownloadDelegate: self, delegateQueue: .main)
    }()
    nonisolated static var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads") }
    func bind(_ store: AppStore) async {
        self.store = store
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let index = Self.directory.appendingPathComponent("queue.json")
            if jobs.isEmpty, FileManager.default.fileExists(atPath: index.path) { jobs = Dictionary(uniqueKeysWithValues: try JSONDecoder().decode([DownloadRecord].self, from: Data(contentsOf: index)).map { ($0.id, $0) }) }
            for task in await http.allTasks + hls.allTasks { if let text = task.taskDescription, let id = UUID(uuidString: text) { tasks[id] = task } }
            publish()
        } catch { store.error = error.localizedDescription }
    }
    private func save() {
        do { try JSONEncoder().encode(Array(jobs.values)).write(to: Self.directory.appendingPathComponent("queue.json"), options: .atomic); lastSaved = Date() }
        catch { store?.error = "下载队列保存失败：" + error.localizedDescription }
        publish()
    }
    private func publish() { store?.downloadProgress = jobs.filter { ["下载中", "等待"].contains($0.value.state) }.mapValues(\.progress) }
    func start(_ item: MediaItem, store: AppStore) {
        guard tasks[item.id] == nil else { return }
        self.store = store; jobs[item.id] = DownloadRecord(item: item); save()
        Task {
            do {
                let resource = try await store.resource(item)
                guard ["http", "https"].contains(resource.url.scheme ?? "") else { throw AppError.message("此来源需要先导入本地，或使用网络文件直链下载。") }
                if resource.url.pathExtension.lowercased() == "m3u8" {
                    let asset = AVURLAsset(url: resource.url)
                    guard let task = hls.makeAssetDownloadTask(asset: asset, assetTitle: item.title, assetArtworkData: nil, options: nil) else { throw AppError.message("无法建立 HLS 离线任务。") }
                    jobs[item.id]?.isHLS = true; task.taskDescription = item.id.uuidString; tasks[item.id] = task; task.resume()
                } else {
                    let resume = try resumeData(item.id)
                    let task: URLSessionDownloadTask
                    if let resume { task = http.downloadTask(withResumeData: resume) }
                    else {
                        var request = URLRequest(url: resource.url)
                        if let user = resource.username, !user.isEmpty { request.setValue("Basic " + Data((user + ":" + (resource.password ?? "")).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
                        if let token = resource.bearerToken { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
                        task = http.downloadTask(with: request)
                    }
                    task.taskDescription = item.id.uuidString; tasks[item.id] = task; task.resume()
                }
                jobs[item.id]?.state = "下载中"; save()
            } catch { jobs[item.id]?.state = "失败"; jobs[item.id]?.error = error.localizedDescription; save() }
        }
    }
    func pause(_ id: UUID) {
        jobs[id]?.state = "已暂停"; save()
        if let task = tasks[id] as? URLSessionDownloadTask {
            task.cancel { [weak self] data in Task { @MainActor in
                do { try self?.storeResume(data, id: id) } catch { self?.jobs[id]?.error = error.localizedDescription }
                self?.tasks[id] = nil; self?.save()
            } }
        } else { tasks[id]?.suspend() }
    }
    func resume(_ id: UUID) {
        if let task = tasks[id] { task.resume(); jobs[id]?.state = "下载中"; save() }
        else if let item = jobs[id]?.item, let store { start(item, store: store) }
    }
    func cancel(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel(); jobs[id] = nil
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(id.uuidString + ".resume")); save()
    }
    private func encryptionKey() throws -> SymmetricKey {
        if let data = try KeychainVault.read(Data.self, account: "download-encryption") { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256); let data = key.withUnsafeBytes { Data($0) }
        try KeychainVault.save(data, account: "download-encryption"); return key
    }
    private func storeResume(_ data: Data?, id: UUID) throws {
        guard let data else { return }
        let box = try AES.GCM.seal(data, using: encryptionKey())
        try box.combined!.write(to: Self.directory.appendingPathComponent(id.uuidString + ".resume"), options: .atomic)
    }
    private func resumeData(_ id: UUID) throws -> Data? {
        let url = Self.directory.appendingPathComponent(id.uuidString + ".resume")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url)), using: encryptionKey())
    }
    private func completed(_ id: UUID, file: URL, managed: Bool) async {
        guard let item = jobs[id]?.item, let store else { return }
        do {
            if managed {
                let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/"
                let path = file.resolvingSymlinksInPath().path
                guard path.hasPrefix(home) else { throw AppError.message("离线资产路径无效。") }
                var local = MediaItem(title: item.title); local.systemAssetPath = String(path.dropFirst(home.count))
                _ = try await store.repository.add(local)
            } else {
                _ = try await store.repository.importFile(file, title: item.title); try? FileManager.default.removeItem(at: file)
            }
            try await store.refresh(); jobs[id]?.state = "已完成"; jobs[id]?.progress = 1; tasks[id] = nil
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(id.uuidString + ".resume")); save()
        } catch { jobs[id]?.state = "失败"; jobs[id]?.error = error.localizedDescription; save() }
    }
}

extension BackgroundDownloads: URLSessionDownloadDelegate, AVAssetDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let text = downloadTask.taskDescription, let id = UUID(uuidString: text) else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw AppError.http((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0) }
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let ext = downloadTask.originalRequest?.url?.pathExtension ?? "mp4"
            let file = Self.directory.appendingPathComponent(UUID().uuidString + "." + (MediaFormats.video.contains(ext) ? ext : "mp4"))
            try FileManager.default.moveItem(at: location, to: file)
            Task { @MainActor in await completed(id, file: file, managed: false) }
        } catch { Task { @MainActor in jobs[id]?.state = "失败"; jobs[id]?.error = error.localizedDescription; save() } }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)), totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in jobs[id]?.progress = value; publish(); if Date().timeIntervalSince(lastSaved) > 1 { save() } }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let message = error.localizedDescription
        Task { @MainActor in
            guard jobs[id] != nil, jobs[id]?.state != "已暂停" else { return }
            do { try storeResume(resume, id: id) } catch { jobs[id]?.error = error.localizedDescription }
            jobs[id]?.state = "失败"; jobs[id]?.error = message; tasks[id] = nil; save()
        }
    }
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = assetDownloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        Task { @MainActor in await completed(id, file: location, managed: true) }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in completions.removeValue(forKey: identifier)?() }
    }
}
