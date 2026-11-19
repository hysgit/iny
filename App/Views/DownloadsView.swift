import SwiftUI

struct DownloadsView: View {
    @ObservedObject private var downloads = BackgroundDownloads.shared
    var body: some View {
        List(Array(downloads.jobs.values).sorted { $0.item.addedAt > $1.item.addedAt }) { job in
            VStack(alignment: .leading, spacing: 8) {
                Text(job.item.title).font(.headline)
                ProgressView(value: job.progress)
                HStack { Text(job.state); Spacer()
                    if job.state == "下载中" { Button("暂停") { downloads.pause(job.id) } }
                    if ["已暂停", "失败"].contains(job.state) { Button("继续") { downloads.resume(job.id) } }
                    Button("移除", role: .destructive) { downloads.cancel(job.id) }
                }.font(.caption)
                if let error = job.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }.navigationTitle("下载")
    }
}
