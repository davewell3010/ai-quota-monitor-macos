#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" Sources/Models.swift tests/main.swift -o build/QuotaTests
build/QuotaTests "$PWD/tests/fake-codex.py"

xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" Shared/WidgetSnapshot.swift tests/widget-main.swift -o build/WidgetTests
build/WidgetTests
