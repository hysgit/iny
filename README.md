# Iny

iPhone / iPad 原生视频播放器与媒体库。Bundle ID 为 `net.icycloud.iny`，源码仓库为 [hysgit/iny](https://github.com/hysgit/iny)。

当前是重建中的工程，**尚未达到原版全部功能等价，也尚未发布 TestFlight**。已实现范围、未实现功能和验收状态分别见 [功能对照](docs/FEATURES.md) 与 [分析报告](docs/2026-11-19_逆向-Iny-report.md)。

## 打开工程

需要 macOS、Xcode 16 或更新版本，以及 CocoaPods。Windows 可以修改源码、提取 IPA 证据及执行静态检查；iOS 编译由独立云端流程执行。

```sh
pod install --repo-update
open Iny.xcworkspace
```

选择 `Iny` Scheme。AMSMB2 固定为 3.4.0，MobileVLCKit 固定为 3.7.5。应用图标、共享 Scheme 和 Xcode 工程已提交，无需先安装 XcodeGen。

```sh
swift test
```

核心包独立于 UI，可在 macOS 和 Linux 执行测试。16 项回归覆盖并发写入、写盘失败回滚、损坏索引保留、文件路径校验、远程来源去重和 WebDAV XML 解析。

## 使用

- 在“媒体库”导入视频或添加 HTTP/HLS 链接。
- 在“文件”连接 WebDAV、SMB、Jellyfin、Emby 或 Plex，浏览目录并加入媒体库。
- 在影片详情中收藏、标记观看、匹配海报、导入字幕或下载 HTTP 视频。
- 在“设置 → 在线服务”填写自己的 TMDB 凭证和 OpenSubtitles 配置。
- VLC 提供通用视频和外部字幕播放；系统播放器提供原生画中画及 AirPlay。

源密码和服务令牌放在系统钥匙串，媒体库索引仅保存资源标识。导出索引不包含凭证和视频文件。视频导入采用复制方式，删除本地库内视频不会删除原始导入文件。

## 云端编译与发布

[Iny iOS](.github/workflows/ios.yml) 先在 Ubuntu 24.04 执行 Swift 核心测试，再在 macOS 编译应用。双设备安装启动已通过；当前新增的播放回归在 iPhone 模拟器用独立 H.264 样片验证播放、暂停和进度保存。构建产物包括模拟器安装包、构建日志和真实界面截图。

[Iny TestFlight](.github/workflows/testflight.yml) 为手动触发的独立发布流程。Apple 后台已建立 Iny App（`6836777599`）和独立的“Iny 内测”组。当前描述文件和签名 Secrets 尚未配置：签名材料上传被自动审批拒绝，尚未执行，需先获得对凭证种类和 GitHub 目的地的明确授权。

[Codemagic 配置](codemagic.yaml) 是另一条独立流程入口，签名集成名称为 `iny`；未创建或修改其他项目的工作流。

发布辅助脚本不会把私钥或访问令牌写进源码。原 IPA、原包提取内容、云端日志和签名目录已被 Git 忽略。**不要将 `.p8`、`.p12` 或描述文件提交到仓库。**

## 复现离线分析

Python 3.11 或更新版本：

```powershell
python scripts/analyze_ipa.py infuse-1136220934.ipa
python scripts/check_sources.py
```

`--swift-parser` 可另外执行 Tree-sitter Swift 语法解析，需要在 `.tools/python` 安装 `tree-sitter` 和 `tree-sitter-swift`。语法检查不等同于 Xcode 编译。

`scripts/generate_project.py` 和 `scripts/generate_icon.py` 用于重建已提交的工程与几何图标。运行工程生成脚本会覆盖 `.pbxproj`，手动修改工程后应同步修改该脚本。
