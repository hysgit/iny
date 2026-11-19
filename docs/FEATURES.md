# Iny 功能对照与验收

范围依据：用户要求恢复 IPA 的全部功能，并明确目标为 iPhone / iPad 原生应用。以下对照保留该范围，不以首个构建成功代表全部完成。

“代码已实现”只表示存在贯通的实现入口。源服务器、真实视频、硬件输出和第三方账号均需各自验收。

| 功能 | 原包可核查证据 | Iny 当前实现 | 当前验证与限制 |
|---|---|---|---|
| 本地视频导入与删除 | 视频类型声明、文件文案 | 已实现复制导入、沙箱存储和删除 | 核心文件事务测试通过；未覆盖所有文件提供程序 |
| 媒体库与海报墙 | `bcLibrary`、元数据文案 | 已实现海报网格、搜索、排序、收藏、观看标记 | iOS 工程已编译；最新界面待模拟器截图复核 |
| 继续观看与进度保存 | `svcResumePlayback`、`vvResumeButton` | 已实现自动保存、断点播放、观看完成标记 | 核心并发测试通过；实际视频恢复待真机 |
| 播放队列、倍速、章节 | `pmPlaybackQueue`、`pmPlaybackSpeed`、章节文案 | 已实现播放队列、连续播放、倍速和 VLC 章节跳转 | 已编译；未完成实际媒体验收 |
| 多容器及音视频解码 | 原包 FFmpeg、dav1d 框架 | 使用 MobileVLCKit；可切换 AVPlayer | 不宣称与原包编码、HDR 或音效能力完全相同 |
| 内嵌音轨、内嵌与外部字幕 | `pmSubtitles` 等 | 已实现 VLC 轨道选择、外部字幕、延迟调节 | 已编译；字幕字体、大小、背景和 HDR 亮度设置未实现 |
| WebDAV | Bonjour 服务与共享文案 | 已实现 Basic 认证、目录浏览、视频串流 | XML、路径、同源和状态解析测试通过；真实 NAS 未联调 |
| SMB | `StratospherixLibSMB.framework`、SMB 文案 | 已实现 AMSMB2 浏览与 VLC SMB 播放入口 | 未完成真实 SMB 2/3 服务联调 |
| NFS、FTP、SFTP 直连 | 原包 `libnfs`、Bonjour 配置与传输文案 | **未实现直接客户端** | iOS 文件提供程序导入不能视作协议等价实现 |
| Jellyfin、Emby | `eyOtherJellyfinServer`、`eyOtherEmbyServer` | 已实现账号登录、分页浏览、直放、观看状态和进度上报 | 未完成真实服务器联调；转码、会话恢复等扩展未实现 |
| Plex | `plConnectToPlex` 等 | 已实现自有令牌直连、分页浏览和直放 | PIN 登录、账户服务器发现、Relay、转码未实现 |
| TMDB 海报与简介 | 原包元数据文案 | 已实现按片名检索并手动匹配 | 需用户自己的 TMDB Token；未实现自动全库刮削 |
| 剧集、合集、评分、演职员 | 原包影片详情与系列文案 | 服务器目录保留季/剧集层级；本地主要为平面媒体库 | 本地剧集聚合、自动合集、演职员页和多站点评分未实现 |
| 本地 NFO、封面与字幕字体 | `hoLocalMetadata`、字体文案 | 外部字幕可导入 | NFO 优先级、相邻封面与字体文件管理未实现 |
| OpenSubtitles | `pmSubtitlesFromOS` 等 | 已实现 API Key、登录、检索与字幕下载 | 未使用真实账号联调；服务配额由用户账号决定 |
| 离线下载 | `fdResumeDownloadButtonTitle` 等 | 已实现 HTTP 文件前台下载、进度和取消 | 后台会话、断点续传、SMB 下载、HLS 离线未实现 |
| AirPlay 与画中画 | `iapFeatureTitleStreaming` 等 | 使用系统播放器的原生控制 | VLC 路径不提供同等输出能力；需设备实测 |
| Google Cast | 原包 GoogleCast 框架与文案 | **未实现** | 设备发现、接收端和字幕投射待实现 |
| iCloud 媒体库同步 | `svcCloudSync` 等 | 仅可从系统文件提供程序导入、导出索引 | 自动云同步、冲突处理和凭证同步未实现 |
| Trakt | `svcConnectToTrakt` 等 | **未实现** | 账号、观看历史、评分与进度同步待实现 |
| Dropbox、Google Drive、OneDrive、阿里云盘直连 | 对应云服务文案 | 可通过已安装的 iOS 文件提供程序导入 | 各家独立 OAuth、浏览与直接串流未实现 |
| 后台播放与锁屏控制 | 原包后台音频配置 | 已配置后台音频及播放会话 | 锁屏元数据与系统遥控命令未实现；后台行为待真机 |
| 应用隐私锁 | `lockTouchIDSubtitle`、密码文案 | 已实现设备密码/生物识别、模态界面遮挡 | 未实现按内容分级、独立四位密码和访客限制 |
| Dolby、DTS、HDR、Dolby Vision | 对应文案与解码框架 | 由所选播放内核和设备实际能力决定 | 未实现与原版等价的专用处理和输出控制 |
| 文件传输、网络上传服务 | 原包 FTP 上传文案 | 已支持系统文件导入与文件共享 | 内置 FTP/HTTP 上传服务未实现 |
| TestFlight | 新增发布要求 | 独立工程、签名配置和上传工作流已编写 | 新 App 记录、签名材料授权及 Apple 处理尚未完成 |

## 验收顺序

1. 核心事务与协议测试、原生编译、iPhone/iPad 启动。
2. 本地 MP4、MKV、多音轨、ASS/SRT、断点播放和后台切换。
3. 用户自己的 WebDAV、SMB、Jellyfin、Emby、Plex 服务逐个联调。
4. 补齐表中明确列出的未实现功能；它们仍属于用户要求的范围。
5. 独立签名、TestFlight 上传、Apple 处理、Iny 内测组分发和真机回归。
