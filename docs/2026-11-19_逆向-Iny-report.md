# Infuse IPA 分析与 Iny 重建报告

分析日期：2026-11-19。报告选型为普通逆向分析，`flavor = null`。

## 概述

用户提供的 IPA 是 Infuse 8.5.10，Bundle ID 为 `com.firecore.infuse`。主程序为 arm64 Mach-O，`LC_ENCRYPTION_INFO_64.cryptid = 1`，因此当前文件不能直接恢复出完整原始 Swift/Objective-C 工程。可读内容包括应用配置、1,567 条简体中文文案、1,544 条英文文案及 60 个框架信息。基于这些证据编写了独立的 Iny 原生工程，Bundle ID 为 `net.icycloud.iny`；现有实现与原版并非全功能等价。[功能对照](FEATURES.md) 明确保留全部待实现范围。

## 范围

授权与外部操作边界见 [scope.md](scope.md)。源码已推送用户指定的 [hysgit/iny](https://github.com/hysgit/iny)。原 IPA 和提取资源保留在本机，不在源码提交中。

## 样本与证据

| E-id | source_ref | 观察 | content_hash / 复现 |
|---|---|---|---|
| E-001 | 原 IPA | 162,287,227 字节，1,605 个 ZIP 成员 | SHA256 `05b6033f00041ccd533fbff21ecba12377f5ae7ead84f32baf5080c2c1719ff3`；运行 `python scripts/analyze_ipa.py infuse-1136220934.ipa` |
| E-002 | `Payload/infuse.app/Info.plist` → `analysis/package-info.json` | 名称 Infuse、版本 8.5.10、构建 8.5.5815、最低 iOS 18 | 与 E-001 同一原包；同命令复现 |
| E-003 | 主 Mach-O 加载命令 → `analysis/encryption.json` | `cryptoff=32768`、`cryptsize=71827456`、`cryptid=1` | 与 E-001 同一原包；同命令复现 |
| E-imports | 主程序导入/依赖 → `analysis/imports.json`、`analysis/libraries.json` | Swift、UIKit、SwiftUI、Foundation、CoreData、Security、CloudKit、GoogleCast、SMB 等依赖 | 本机已运行 `rabin2 -ij analysis/extracted/infuse`、`rabin2 -lj analysis/extracted/infuse`；原始可执行文件不提交 |
| E-004 | `zh-Hans.lproj/Localizable.strings`、框架清单 → `analysis/feature-catalog.json` | 可定位播放、字幕、网络共享、媒体服务器、云盘、同步、投屏和高级音视频入口 | 与 E-001 同一原包；同提取脚本复现 |
| E-005 | [云构建 44524740188](https://github.com/hysgit/iny/actions/runs/44524740188) | 提交 `8d87bbf` 的 Linux 与 macOS 各 16 项测试通过，iOS 模拟器应用编译成功 | GitHub Actions 构建日志；本机副本位于 `analysis/cloud/44524740188/` |
| E-006 | `scripts/apple_account.py` 的 API 响应 | Iny Bundle ID 已注册，资源 ID `H2G5323M9F`；检查时尚无 Iny App 记录 | 需持有本机授权 Apple API 私钥；公开源码与报告不包含私钥或 JWT |
| E-007 | 当前 `App/` 与 `Iny.xcodeproj/` | 新 SwiftUI 界面、VLC/AVPlayer、媒体库事务及网络来源实现 | `python scripts/check_sources.py --swift-parser`；Xcode 与 Swift 测试结果分别记录，不混同语法检查 |
| E-008 | [云构建 44525758708](https://github.com/hysgit/iny/actions/runs/44525758708) | 提交 `860d9ed` 的 iPhone/iPad 安装、启动与截图成功；本机已逐图复核 | `analysis/cloud/44525758708/artifacts/previews/`，运行 `python scripts/fetch_artifacts.py 44525758708 --previews-only` 取回 |
| E-009 | 独立 Apple App 与内测组 API/UI | Iny App ID `6836777599`；“Iny 内测”组 `890170cc-8b9c-4fa3-8933-562df45227d0`，内部组 | 本机记录 `analysis/apple-app.json`；不含账号密码、API 私钥或 JWT |

### Findings

| F-id | severity | evidence_ids | confidence | location | status | 结论 |
|---|---|---|---|---|---|---|
| F-001 | n/a_re | E-001、E-002、E-003 | high | 主程序加载命令 | validated | 主程序仍标记 App Store 加密；不能把字符串/资源提取称为完整源码恢复 |
| F-002 | n/a_re | E-imports、E-004 | high | 配置、依赖及本地化资源 | validated | 可建立可复查的功能入口清单；文案或框架存在不证明具体运行行为 |
| F-003 | n/a_re | E-005、E-007 | high | 新核心包与原生工程 | validated | 新实现已经过真实 Swift 测试和一轮 iOS 编译；不代表真实 NAS、所有编码或完整原版行为验收 |
| F-004 | n/a_re | E-006、E-009 | high | Apple 新应用配置 | validated | Bundle ID、独立 App 记录和内部组均已建立；当前未完成签名及 TestFlight 发布 |

### P-001

- path_type：solve
- start：用户提供的 IPA。
- goal：建立可维护、可编译的独立 iPhone/iPad 工程，并按完整功能范围继续重建。
- steps：E-001 固定样本身份 → E-002/E-003 确认可读范围和加密限制 → E-imports/E-004 建立功能证据 → E-007 重写核心与界面 → E-005/E-008 实际云编译、回归及双设备启动 → E-006/E-009 独立应用标识、App 记录和内测组 → 待授权签名并发布 TestFlight。

## 新工程实现

媒体库通过 actor 执行无挂起点的读改写事务，先原子落盘，再公布新快照。快照包含递增版本，主线程不接受更早的异步响应。源服务器删除后，迟到的网络结果不能重新加入已删来源。坏索引不会被空库覆盖，导入采用复制方式，删除索引后才清理库内文件。

网络 API 使用短时会话，登录信息保存至钥匙串。远程媒体索引保存来源和资源标识，播放 URL 按需生成；主动添加的 URL 拦截已知的令牌参数。该规则不能识别任意服务自定义的所有秘密字段，因此不应把任意签名 URL 当作普通永久链接保存。

播放使用全新集成的 MobileVLCKit / AVPlayer，并未复制原包 FFmpeg 二进制或业务实现。UI 使用 SwiftUI，当前没有原应用的运行截图或交互轨迹，因此不能声称视觉与交互已逐像素还原。

## 关键验证

- 并发 100 次新增后完整保留全部条目，并重新打开索引比对标识集合。
- 验证写盘失败不发布新状态，坏 JSON 不被覆盖，源文件不因库内删除而丢失。
- 验证路径穿越、来源删除后迟到请求、跨来源去重和进度/收藏同时修改。
- 验证 WebDAV 命名空间、相对地址、中文、XML 转义、失败属性及跨源条目。
- 云测试发现 Linux XMLParser 对截断 XML 的返回行为不足以单独判断完整性；新增错误回调、元素深度和根节点校验后，16 项测试全部通过。
- iPhone/iPad 安装、启动与截图流程已通过并逐图复核。另加真实 H.264 样片的播放/暂停/保存进度 UI 验收，当前仍在运行，不能把启动成功写成已验证实际解码。

## 未完成与限制

完整待办见 [功能对照](FEATURES.md)，包括 NFS/FTP/SFTP 直连、独立云盘 OAuth、iCloud/Trakt 同步、Google Cast、后台断点下载以及更多字幕和高级音视频设置。原包加密区、原应用运行行为、真实媒体服务和硬件表现均未被静态资源证明。

签名与 TestFlight 工作流已写入独立仓库配置，但向 GitHub 保存现有 Apple API 私钥及签名材料的执行请求被自动审批拒绝。此步骤未执行，也没有新建签名证书或上传私钥。Apple 新 App 记录与内测组已通过独立浏览器创建；未向其他应用的测试组分发，也未邀请其他测试员。

## 时间线

2026-11-19 依次完成：固定样本哈希与配置 → 确认加密区 → 提取文案与依赖 → 建立新 Swift 工程 → 用户确定名称 Iny 与独立包标识 → 推送用户指定仓库 → 注册新 Bundle ID → 真实 Swift 测试发现并修复 XML 问题 → Linux/macOS 测试及 iOS 编译通过 → 新增最新构建的双设备启动截图流程。签名材料上传因自动审批拒绝暂停，未将其写成已发布状态。
