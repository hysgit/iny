import SwiftUI

struct SubtitleStyleView: View {
    @AppStorage("subtitleFont") private var font = "Helvetica Neue"
    @AppStorage("subtitleSize") private var size = 5
    @AppStorage("subtitleOpacity") private var opacity = 255
    @AppStorage("subtitleBackground") private var background = 0
    @AppStorage("subtitleOutline") private var outline = 2
    @AppStorage("subtitleColor") private var color = 16777215
    @State private var importing = false
    @State private var error: String?
    var body: some View {
        Form {
            Text("字幕预览 Subtitle preview").font(.custom(font, size: CGFloat(size * 4))).foregroundStyle(Color(red: Double((color >> 16) & 255) / 255, green: Double((color >> 8) & 255) / 255, blue: Double(color & 255) / 255)).opacity(Double(opacity) / 255)
            Picker("字体", selection: $font) { ForEach(UIFont.familyNames.sorted(), id: \.self) { Text($0).tag($0) } }
            Button("导入字体") { importing = true }
            Stepper("大小 \(size)%", value: $size, in: 2...12)
            Picker("文字颜色", selection: $color) { Text("白色").tag(16777215); Text("黄色").tag(16776960); Text("灰色").tag(12632256) }
            Picker("文字透明度", selection: $opacity) { Text("100%").tag(255); Text("75%").tag(191); Text("50%").tag(127) }
            Picker("背景", selection: $background) { Text("透明").tag(0); Text("50%").tag(127); Text("不透明").tag(255) }
            Stepper("描边 \(outline)", value: $outline, in: 0...4)
            Text("更改样式后重新打开影片即可应用。").font(.footnote).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("字幕样式")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            do { font = try FontLibrary.importFont(result.get()) } catch { self.error = error.localizedDescription }
        }
    }
}
