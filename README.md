# AIUsageBar

AIUsageBar 是一个 macOS 状态栏应用，使用 SwiftUI 绘制界面、AppKit 管理状态栏生命周期，当前接入 Codex 用量 provider。项目使用 Swift Package Manager 管理构建，不依赖第三方运行时；后续新增 Claude Code 等 provider 时只需要实现 `UsageProvider`。面板顶部显示所有 provider 的 Token 消耗总和，菜单栏仅显示剩余百分比文本。

## 开发环境

- macOS 13 或更高版本
- Xcode 26+ / macOS 26+ SDK（编译原生 Liquid Glass API；运行最低仍为 macOS 13）
- Swift Package Manager（随 Xcode 提供）

打开项目：

```sh
open Package.swift
```

Xcode 会直接识别 Swift package。日常开发可以使用 Xcode 的 Run/Test、断点、内存图和 Instruments，也可以使用仓库内的命令行入口。

## 常用命令

```sh
make build     # Debug 构建
make test      # 测试
make run       # 直接运行 SwiftPM 可执行文件
make dev       # 运行应用，并实时显示统一日志
make logs      # 只查看已运行应用的日志
make check     # 检查 package 描述并执行 Release 构建
make package   # 生成 dist/AIUsageBar.app 和 zip
make dmg       # 在 package 基础上生成 DMG
make clean     # 清理构建和分发产物
```

## 本地实时调试

应用使用 Apple Unified Logging，日志 subsystem 是 `com.silfoxs.AIUsageBar`，分类包括 `app`、`usage` 和 `ui`。推荐在一个终端运行：

```sh
make dev
```

该命令会启动应用并执行 `log stream`，刷新 provider、打开设置和应用启动等事件会实时出现在终端。需要单独过滤或查看已运行实例时使用：

```sh
AI_USAGE_LOG_SUBSYSTEM=com.silfoxs.AIUsageBar make logs
```

在 Console.app 中也可以按 subsystem 过滤；在 Xcode 中则使用断点和 Debug Memory Graph 检查 UI 与状态生命周期。

## 打包与签名

`make package` 执行 Release 构建，并按标准 macOS bundle 结构创建：

```text
dist/AIUsageBar.app/
└── Contents/
    ├── Info.plist
    ├── MacOS/AIUsageBar
    └── Resources/
```

`Packaging/Info.plist` 配置了状态栏应用必需的 `LSUIElement`、bundle identifier 和最低系统版本。脚本默认使用 ad-hoc 签名，适合本机验证；发布时将 Developer ID identity 传给 `CODESIGN_IDENTITY`：

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
APP_VERSION=1.0.0 make package
```

生成 `dist/AIUsageBar-1.0.0.zip`。需要 DMG 时执行 `make dmg`。正式发布前还需要在具备 Apple Developer 证书和公证凭据的机器上完成 notarization，例如：

```sh
xcrun notarytool submit dist/AIUsageBar-1.0.0.zip \
  --keychain-profile "AC_NOTARY" --wait
xcrun stapler staple dist/AIUsageBar.app
```

签名脚本没有使用 `sudo`，也没有依赖 `codesign --deep`；当前 bundle 只有主可执行文件，后续加入嵌套 framework、helper 或 extension 时，应按嵌套代码的签名顺序分别签名，再签名 app bundle。

## CI

`.github/workflows/macos.yml` 在 macOS runner 上执行 Release 构建、生成未签名验证包，并检查 app bundle、Info.plist 和代码签名结构。证书和公证凭据不应提交到仓库；发布工作流可以通过 GitHub Actions secrets 注入 `CODESIGN_IDENTITY`、签名证书和 notarytool profile。

## 目录约定

```text
Sources/AIUsageBar/       SwiftUI、AppKit 和 usage provider
Packaging/                Info.plist、entitlements
scripts/                  开发、日志、app bundle、DMG 脚本
.github/workflows/        CI 构建检查
```

真实 Codex 数据通过 `Sources/AIUsageBar/CodexClient.swift` 连接本机 `codex app-server` 的只读接口读取，认证和 token 刷新由 Codex CLI 自己处理，应用不会读取或保存 `~/.codex/auth.json`。目前使用 `account/rateLimits/read` 读取剩余比例、额度窗口、重置时间、重置卡数量和到期时间，使用 `account/usage/read` 读取账户 lifetime token 总量和每日 token 桶。

首次使用前请确认：

```sh
codex --version
codex login
```

如果 Codex CLI 不在 PATH 中，可以通过 `AI_USAGE_CODEX_PATH=/absolute/path/to/codex` 指定路径。应用启动时读取一次，打开面板时按当前刷新间隔检查是否需要更新，自动刷新频率可以在设置中选择：极速 10 秒、快 30 秒、标准 1 分钟、慢 3 分钟、超慢 5 分钟，默认标准 1 分钟，修改立即生效并持久保存；已有请求未完成时跳过重复请求。底部的 Refresh 可立即刷新。网络失败、接口不兼容或未登录时会显示明确提示，并保留上一次成功读取的数据。

选择设置中的应用只控制用量区域显隐；顶部总 Token 会汇总所有 provider 的完整数据。只要有一个 provider 的真实数据缺失，总和会显示 `—`，不会用零或演示值伪造总量。

每个 provider 区域还会展示最近 7 天的日消耗柱状图，同时显示包含今天的累计 Token 和最近 30 天合计。当天日桶存在时，今日使用官方数据；当天日桶缺失时，应用会读取本机 `~/.codex/sessions` 和 `archived_sessions` 中的 `token_usage_record`，按 `response_id` 去重后显示“今日 · 本地估算”，并把估算值加入界面上的累计和 30 天合计。官方日桶出现后自动优先使用官方值。没有可用本地记录时，今日显示暂无数据。

本地今日估算是设备活动指标，不是账户最终账单：它可能遗漏远程压缩、失败重试或其他后台请求。读取器会缓存未变化的 session 文件，每次刷新只重新解析发生变化的文件，并同时支持当前 session 目录和归档目录。

菜单栏只显示百分比文本；面板宽度控制在 360pt，隐藏滚动条并保留两侧内容边距。每个 provider 的额度、重置卡和 Token 图表是独立区域，鼠标悬停时只给当前区域加深色圆角背景，不改变其他区域。设置窗口只会由面板底部的 Settings 按钮显式打开，点击菜单栏时不会恢复或弹出设置窗口。刷新按钮位于底部“上次刷新”时间左侧；每次请求完成都会更新时间，即使服务端返回的 Token 数值没有变化也会明确提示。

## 参考

- [Swift Package Manager Package Description](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html)
- [Apple: Placing content in a bundle](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle)
- [Apple: Logger and Unified Logging](https://developer.apple.com/documentation/os/logger)
- [Apple: Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)

## 界面材质

macOS 26+ 使用不带 tint 的原生 `glassEffect(.regular)` ；按钮采用简洁的无边框样式；macOS 13–25 回退到系统 material。面板本身保持透明，避免出现额外灰色底板；设置页使用系统 Liquid Glass 材质。额度窗口使用进度条，30 天图表使用蓝色和靛青色，异常提示保留语义色。
