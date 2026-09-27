# AI Quota Monitor for macOS

A native SwiftUI/AppKit menu-bar card and WidgetKit extension for viewing Codex and Claude subscription usage. It shows five-hour and weekly usage percentages, remaining allowance, reset times, themes, custom backgrounds, and Simplified Chinese/English UI.

> This is an independent community project. It is not affiliated with or endorsed by OpenAI or Anthropic.

## Features

- Codex and Claude five-hour and weekly subscription usage.
- Floating card, menu-bar controls, and small/medium/large macOS widgets.
- Built-in themes and local custom background images.
- Simplified Chinese and English display languages.
- Codex executable auto-detection, program selection, path paste/copy, and browser sign-in through the official Codex CLI.
- Configurable refresh interval, always-on-top mode, and launch at login.
- No project server, analytics, or manual API-key entry.

Values are subscription usage percentages, not token counts. WidgetKit controls desktop-widget refresh timing.

## Requirements

- macOS 14 or later.
- Xcode and Xcode Command Line Tools.
- A locally signed-in Codex app/CLI.
- A Claude account signed in through the app's isolated WebKit window.
- An Apple Development certificate and App Group capability for widgets.

## Build

Floating card:

```bash
./scripts/build.sh
./scripts/test.sh
open "build/AI额度.app"
```

App with WidgetKit extension:

```bash
./scripts/build-widget.sh
open "build/widget/AI额度.app"
```

The default bundle identifier is `io.github.aiquota.monitor`. Public identifiers can be overridden:

```bash
APP_BUNDLE_ID=com.example.aiquota \
WIDGET_BUNDLE_ID=com.example.aiquota.widget \
APP_GROUP_ID=YOURTEAMID.com.example.aiquota \
./scripts/build-widget.sh
```

After launch, right-click the desktop, choose **Edit Widgets**, and search for **AI 额度**.

## Data and privacy

- **Codex:** starts the local `codex app-server --stdio` process and calls read-only `account/rateLimits/read`. The **Sign in to Codex** button starts the official `codex login` browser flow and uses Codex's own local credential storage; this app does not collect or save the password or tokens.
- **Claude:** uses a dedicated local WebKit session on the official Claude website. It does not read Safari or Chrome cookies.
- **Widget:** receives only percentages, reset dates, timestamps, failure flags, and language through an App Group JSON snapshot.
- **Custom themes:** images are resized and saved locally under Application Support.
- Cookies, OAuth tokens, API keys, and credentials are not written to the widget snapshot or logs.

Claude's website endpoints are not a documented stable public API and may change or require browser verification.

## Development

```bash
./scripts/test.sh
xcrun swiftc -typecheck -swift-version 5 \
  -framework AppKit -framework SwiftUI -framework WebKit \
  -framework WidgetKit -framework ServiceManagement \
  Sources/*.swift Shared/*.swift
```

`scripts/verify-widget.sh` checks extension metadata, entry point, App Group configuration, and signatures.

## Project structure

```text
Sources/          App UI, providers, settings, themes, and widget bridge
Shared/           Data shared by the host app and widget
Widget/           WidgetKit provider and layouts
WidgetExtension/  Xcode extension target
Resources/        Bundled visual assets
scripts/          Build and verification utilities
tests/            Offline Swift and simulated RPC tests
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports should follow [SECURITY.md](SECURITY.md).

## License

Released under the [MIT License](LICENSE). Product names and trademarks belong to their owners.

---

## 中文简介

AI Quota Monitor 是原生 macOS 悬浮卡片和桌面小组件，用于查看 Codex 与 Claude 官方订阅的五小时、周额度使用率、剩余比例和重置时间。支持多主题、自定义背景、简体中文/英文切换和菜单栏运行。

本项目不提供 token 精确统计，不上传账号凭据，也不要求手工填写 API Key。Claude 数据依赖其网页接口，网页变化时可能需要更新适配。
