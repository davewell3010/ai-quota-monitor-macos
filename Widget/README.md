# WidgetKit extension

The host app reads quota data and writes a minimal JSON snapshot to a team-prefixed App Group. The extension never reads account cookies or Codex authentication files.

```bash
./scripts/build-widget.sh
./scripts/verify-widget.sh
```

Output: `build/widget/AI额度.app`. Keep the menu-bar host running to refresh data. macOS assigns WidgetKit refresh budgets and may delay visual updates.

The host and extension must use the same Apple Development team and App Group. See the repository [README](../README.md) for configurable bundle identifiers and complete setup.

Relevant files:

- `Widget/AIQuotaWidget.swift`
- `Shared/WidgetSnapshot.swift`
- `Sources/WidgetBridge.swift`
- `WidgetExtension/AIQuotaWidget.xcodeproj`
