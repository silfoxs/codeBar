# codeBar

codeBar 是一款 macOS 状态栏应用，用来快速查看 Codex 账户用量。它常驻在菜单栏中，以百分比显示当前额度，点击后可以查看额度窗口、重置卡、Token 消耗和近期用量趋势。

项目使用 SwiftUI 构建界面、AppKit 管理状态栏窗口，并通过 Swift Package Manager 管理构建。当前内置 Codex provider，后续可以继续接入其他 AI 应用。

## 功能

- 在菜单栏显示当前可用额度百分比
- 查看主额度窗口、重置时间、可用重置卡和最早到期时间
- 查看累计 Token、今日用量、最近 7 天图表和最近 30 天统计
- 支持中文和 English 界面
- 自定义显示的 provider 和自动刷新频率
- 支持手动刷新，并显示最近一次读取时间
- 支持 macOS 13 及更高版本；在较新系统上使用 Liquid Glass 风格

## 使用

### 环境要求

- macOS 13 或更高版本
- Xcode 26+（用于编译最新系统上的 Liquid Glass API）
- [Codex CLI](https://github.com/openai/codex)，并已完成登录

首次使用前，在终端执行：

```sh
codex --version
codex login
```

如果 `codex` 不在 `PATH` 中，可以在启动前指定可执行文件路径：

```sh
AI_USAGE_CODEX_PATH=/absolute/path/to/codex make run
```

### 启动应用

直接运行 Swift Package：

```sh
make run
```

应用启动后会出现在菜单栏。点击菜单栏图标打开用量面板：

1. 点击 **Refresh** 立即读取最新数据。
2. 点击 **Settings** 选择语言、要显示的 provider 和刷新频率。
3. 关闭面板后，应用会继续按设置的频率自动刷新。
4. 在设置页的“软件更新”区域点击 **检查更新**。发现新版本后，确认即可下载、校验并自动替换应用。

当天官方用量数据尚未提供时，今日用量可能显示为“本地估算”。该数值来自本机 Codex session 活动，用于即时参考；官方数据出现后会自动优先使用官方数据。

## 构建与测试

使用 Xcode 打开项目：

```sh
open Package.swift
```

也可以使用 Makefile：

```sh
make build     # Debug 构建
make test      # 运行测试
make check     # 检查 package 并执行 Release 构建
make clean     # 清理构建和分发产物
```

本地开发时如需同时查看统一日志：

```sh
make dev       # 启动应用并实时显示日志
make logs      # 查看已运行应用的日志
```

## 打包发布

生成 macOS 应用包和 zip：

```sh
make package
```

产物位于 `dist/`：

```text
dist/codeBar.app
dist/codeBar-0.1.0.zip
```

生成带 Finder 拖放安装界面的 DMG：

```sh
make dmg
```

默认使用 ad-hoc 签名，适合本机验证。发布时可以指定 Developer ID 和版本号：

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
APP_VERSION=1.0.0 make package
```

发布工作流会将 DMG 和 zip 上传到 GitHub Release。更新器读取仓库的最新正式 Release；草稿 Release 不会出现在更新列表中。

## 数据与隐私

codeBar 通过本机 Codex CLI 的 `app-server` 只读接口读取账户用量。登录状态和凭据由 Codex CLI 管理，应用不会读取或保存 `~/.codex/auth.json`，也不会上传用量数据到其他服务。

## 项目结构

```text
Sources/codeBar/       应用、界面、用量模型和 Codex provider
Tests/codeBarTests/    单元测试
Packaging/             Info.plist、entitlements 和应用资源
scripts/               开发、日志、打包和 DMG 脚本
.github/workflows/     macOS CI 构建检查
```
