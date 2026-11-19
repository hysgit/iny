import Foundation
import SwiftUI
#if canImport(GoogleCast)
import GoogleCast
#endif

@MainActor
enum CastService {
    static func configure() {
        #if canImport(GoogleCast)
        let options = GCKCastOptions(discoveryCriteria: GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID))
        GCKCastContext.setSharedInstanceWith(options)
        #endif
    }
    static func play(_ item: MediaItem, store: AppStore) async throws {
        #if canImport(GoogleCast)
        guard let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession,
              let client = session.remoteMediaClient else { throw AppError.message("请先使用投屏按钮选择 Google Cast 设备。") }
        let url: URL
        if let filename = item.localFilename { url = try await LocalMediaServer.shared.file(store.repository.localURL(filename), onLAN: true) }
        else {
            let resource = try await store.resource(item)
            guard resource.username?.isEmpty != false else { throw AppError.message("此认证共享请通过媒体服务器兼容转码后投屏。") }
            url = try LocalMediaServer.shared.lanURL(resource.url)
        }
        let metadata = GCKMediaMetadata(metadataType: .movie)
        metadata.setString(item.title, forKey: kGCKMetadataKeyTitle)
        if let poster = item.posterURL { metadata.addImage(GCKImage(url: poster, width: 500, height: 750)) }
        let media = GCKMediaInformationBuilder(contentURL: url)
        media.metadata = metadata; media.streamType = .buffered; media.streamDuration = item.duration
        media.contentType = url.pathExtension == "m3u8" ? "application/x-mpegURL" : "video/mp4"
        let load = GCKMediaLoadRequestDataBuilder(); load.mediaInformation = media.build(); load.startTime = item.position; load.autoplay = true
        client.loadMedia(with: load.build())
        #else
        throw AppError.message("此构建未包含 Google Cast。")
        #endif
    }
}

struct CastDeviceButton: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        #if canImport(GoogleCast)
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 44, height: 44)); button.tintColor = .orange; return button
        #else
        return UIView()
        #endif
    }
    func updateUIView(_ view: UIView, context: Context) { }
}
