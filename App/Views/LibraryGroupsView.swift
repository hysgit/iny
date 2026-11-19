import SwiftUI

struct LibraryGroupsView: View {
    @EnvironmentObject private var store: AppStore
    var series: Bool
    private var groups: [String: [MediaItem]] {
        Dictionary(grouping: store.library.items.filter { series ? $0.seriesTitle != nil : $0.collection != nil }) { series ? $0.seriesTitle! : $0.collection! }
    }
    var body: some View {
        List(groups.keys.sorted(), id: \.self) { name in
            NavigationLink(name) {
                List((groups[name] ?? []).sorted { ($0.season ?? 0, $0.episode ?? 0, $0.title) < ($1.season ?? 0, $1.episode ?? 0, $1.title) }) { item in
                    NavigationLink { MediaDetailView(itemID: item.id) } label: {
                        HStack { Text(item.title); Spacer(); if let season = item.season, let episode = item.episode { Text(String(format: "S%02dE%02d", season, episode)).foregroundStyle(.secondary) } }
                    }
                }.navigationTitle(name)
            }
        }.navigationTitle(series ? "剧集" : "电影系列")
    }
}
