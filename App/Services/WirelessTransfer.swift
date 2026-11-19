import Foundation
import Combine
#if canImport(GCDWebServer)
import GCDWebServer
#endif

@MainActor
final class WirelessTransfer: NSObject, ObservableObject {
    @Published var address: URL?
    @Published var password = ""
    @Published var error: String?
    var imported: ((URL) async -> Void)?
    #if canImport(GCDWebServer)
    private var server: GCDWebUploader?
    #endif
    func start() {
        #if canImport(GCDWebServer)
        do {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WirelessInbox")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let uploader = GCDWebUploader(uploadDirectory: folder.path)
            uploader.allowedFileExtensions = Array(MediaFormats.video)
            uploader.delegate = self; password = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))
            try uploader.start(options: [GCDWebServerOption_Port: 0, GCDWebServerOption_BonjourName: "Iny", GCDWebServerOption_AuthenticationMethod: GCDWebServerAuthenticationMethod_DigestAccess, GCDWebServerOption_AuthenticationAccounts: ["iny": password]])
            server = uploader; address = uploader.serverURL
        } catch { self.error = error.localizedDescription }
        #else
        error = "此版本未包含无线传输服务。"
        #endif
    }
    func stop() {
        #if canImport(GCDWebServer)
        server?.stop(); server = nil
        #endif
        address = nil; password = ""
    }
}

#if canImport(GCDWebServer)
extension WirelessTransfer: GCDWebUploaderDelegate {
    nonisolated func webUploader(_ uploader: GCDWebUploader, didUploadFileAtPath path: String) {
        let url = URL(fileURLWithPath: path)
        Task { @MainActor in
            await imported?(url)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
#endif
