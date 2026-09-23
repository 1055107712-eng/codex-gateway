# CodexGateway CN Test — IMPLEMENTATION PLAN

> 目标：源码 clone 中开发代号 `CodexGateway CN Test` 的个人增强版，不触碰 `/Applications/CodexGateway.app`。
> 本轮仅规划，确认后再动手改代码。

---

## 0. 核实的基线事实（2026-09-23）

| 项 | 现状 |
|---|---|
| 源码 clone | `/tmp/codex-gateway-repro/repro`，detached at `v0.1.17` (`fef301f`) |
| zstd 状态 | 工作树已含修复版 `GatewayServer / LoopbackHTTPServer / ZstdBridge.swift`（未提交），与持久补丁内容一致（`git apply --reverse --check` OK） |
| 持久补丁 | `~/Documents/CodexGateway-Patches/2026-09-23/{codexgateway-zstd-fix, codexgateway-zstd-tests}.patch` |
| 修复补丁 pristine check | apply-check **PASS**（已在隔离 worktree 验证） |
| 测试补丁 | harness-only，目标 `Sources/Runner/main.swift`，不存在于正式 repo |
| 本机构建能力 | 仅 CommandLineTools，无完整 Xcode；纯 Foundation 逻辑可 `swift test`，含 SwiftUI/SwiftUIMacros 的编译必须走 CI |
| App 身份 | `AppIdentity.productName=CodexGateway`，bundle id `com.rimusz.CodexGateway` |
| config 管理 | `CodexConfig` 用 `# >>> codexgateway managed >>>` 标记块管理 `model_provider/model_catalog_json/openai_base_url` 与 `[model_providers.codexgateway]` |
| 构建脚本 | `build-macos-app.sh` 支持 `--name`（改 CFBundleName），但 Info.plist 的 bundle id 硬编码 |

---

## 1. 目标 App 命名与隔离

- App 显示名：`CodexGateway CN Test`
- **Bundle Identifier：新值 `com.rimusz.CodexGateway.CNTest`**（必须改，否则与正式 App 同 id 会造成 LaunchServices 冲突 / Open at Login 互相覆盖）。
- 产出独立 `CodexGateway CN Test.app`，**绝不写入 `/Applications/CodexGateway.app`**；正式版保留。
- 版本：沿用 `VERSION`（`0.1.17`），在根 `VERSION` 或独立 `VERSION-CN` 中标注 `-cn` 后缀，避免与正式 release tag 冲突。

**改哪些文件**
- `CodexGateway/Services/AppIdentity.swift`：新增 `cnTestProductName`/`cnTestBundleIdentifier`，并把 bundle id / product name 改为可从 `ProcessInfo` 环境变量或编译宏(`-D CN_TEST`)覆盖 —— 这样同一套源码可出双版本，正式版行为不变。
- `scripts/build-macos-app.sh`：新增 `--bundle-id` 参数；`--name` 已支持；Info.plist 从硬编码改为变量。
- 不新增 Xcode project（遵守 AGENTS.md「stay on SwiftPM」）。

---

## 2. 简体中文本地化

### 原则
优先用 **SwiftUI / Apple 官方本地化**，核心 UI 字符串不硬编码中文。技术词汇按你的映射翻译，品牌名不翻。

### 方案（无 xcodeproj、SwiftPM 环境）
两层并用：

1. **字符串资源层**（官方 Localizable）
   - 新建 `CodexGateway/Resources/zh-Hans.lproj/Localizable.strings`、`en.lproj/Localizable.strings`。
   - `Package.swift` 的 `resources` 增加 `.process("Resources/…lproj")`，并设置 `knownRegions` 含 `en`、`zh-Hans`，`defaultLocalization`。
   - UI 字符串统一改用 `LocalizedStringKey`（SwiftUI `Text("key")`）或 `String(localized:)`（Foundation）。
   - **AppKit 部分**（菜单栏 `StatusBarController`、`OpenAtLoginMenuCopy` 等）用 `NSLocalizedString`，同样走同一 strings 文件 —— 保证“主界面 + 设置页”都覆盖。

2. **语言切换层**（`自动 / 简体中文 / English`）
   - 新增 `CodexGateway/AppLanguage.swift`：`enum Language { auto, zh, en }`，持久化到 `UserDefaults`（`codexgateway.ui.language`）。
   - `auto` = 跟随 `Bundle.main.preferredLocalizations` / 系统 locale；`zh`/`en` = 固定覆盖。
   - SwiftUI 视图通过 `.environment(\.locale, lang.locale)` 实时切换，无需重启；AppKit 菜单栏在语言变更通知时重建菜单项标题。
   - 设置页放一个 `Picker("语言 / Language")` 三项。
   - 技术词映射只做**文案**；`Base URL→API 地址（Base URL）`、`Provider→提供商`、`Model ID→模型 ID`；`GPT/OpenAI/Codex/CodexGateway/Zhishu/Agnes/API/Responses API` 保持原文。

### 覆盖清单（设置页 + 主界面）
设置页：Settings/设置、Models/模型、Providers/提供商、Status/状态、Running/运行中、Stopped/已停止、Start/启动、Stop/停止、Restart/重启、Save/保存、Apply/应用、Test Connection/测试连接、Logs/日志、Advanced/高级设置、About/关于、Version/版本。菜单栏 + 关于窗 + Doctor 关键标签同覆盖。

**改哪些文件**
- 新增 `CodexGateway/AppLanguage.swift`
- `CodexGateway/UI/SettingsView.swift`（字符串切 `LocalizedStringKey` + 语言 Picker）
- `CodexGateway/UI/SettingsWindowController.swift`（window title 本地化）
- `CodexGateway/StatusBarController.swift`、`CodexGateway/UI/AboutWindowController.swift`（AppKit 词条）
- `CodexGateway/main.swift` / `AppDelegate.swift`（注入语言环境）

> 说明：动态表格文案（provider 名、model 名、Base URL 值）是**数据**，一律不翻。

---

## 3. 模型线路切换 UI

### 放置
`SettingsView` 新增一个 **`模型线路 / Model Route` Section（放置在最顶部，状态卡下方）**，由新增 `RouteSectionView` 承载。

### 状态卡（只读，不显示 token/key）
- `模型线路/Model Route`：`OpenAI 官方` 或 `CodexGateway`
- `Gateway 状态`：运行中 / 未运行（探测 `127.0.0.1:8765/health`）
- `Gateway 地址`：`127.0.0.1:8765`
- `当前 Codex model_provider`：`openai` / `codexgateway`
- `当前模型`：`gpt-5.6-sol` / `zhishu-auto/zhishu-auto`

### 切换按钮（动态）
- 当前 Gateway → 按钮 **`切换到官方 GPT`**
- 当前 OpenAI 官方 → 按钮 **`切换回 CodexGateway`**
- 切换成功 toast：`已切换到 OpenAI 官方。请重新启动 Codex 使设置完全生效。` / `已切换到 CodexGateway。请重新启动 Codex 使设置完全生效。`
- **不自动 kill Codex**；仅检测 Codex.app 是否运行并展示状态提示。

**改哪些文件**
- 新增 `CodexGateway/UI/RouteSectionView.swift`（状态卡 + 按钮 + toast）
- `CodexGateway/UI/SettingsView.swift`（body 顶部挂 RouteSection）

---

## 4. `~/.codex/config.toml` 安全修改器

### 设计：`CodexConfigRoute`（独立于现有 `CodexConfig.patchCodexConfig`）
这是本任务最敏感的部分。**不复用** `patchCodexConfig`（它走“整块 strip 重建 managed block”，会整体改写文件、可能重排注释）。新增**行级定点编辑器**，只动目标顶层字段。

### 修改范围（严格限定顶层区）
- 打开文件，逐行扫描；**只在第一个顶层 `[` section 之前**处理下列字段；`[model_providers.*]`、`[mcp_servers.*]`、所有注释、`[projects.*]` 等完全不动。
- 目标字段（顶层 3 键）：

| 开关 | model_provider | model | 顶层 openai_base_url |
|---|---|---|---|
| OpenAI 官方 | `"openai"` | `"gpt-5.6-sol"` | **注释而非删除**（`# openai_base_url = "http://127.0.0.1:8765/v1"`），保留原文可恢复 |
| CodexGateway | `"codexgateway"` | `"zhishu-auto/zhishu-auto"` | 恢复为激活状态 `openai_base_url = "http://127.0.0.1:8765/v1"`（若原被注释则还原） |

- 处理算法（一次遍历，写临时 buffer）：
  1. 行若在 `[model_providers.codexgateway]` 等 section 内 → 原样保留。
  2. 行若在顶层且命中 `model_provider`/`model`/`openai_base_url`（含 `# ` 前缀的注释变体）→ 按上表改写。
  3. 兜底：若目标字段在顶层缺失，则在第一个 `[` section 前**插入**（不破坏任何现有 block）。
- 全程 **不把整文件重新序列化**，只做行替换/注释/新增，保留所有注释、空行、其他键与 provider tables。

### 安全机制（每次修改前必做）
1. **备份**：复制原始文件 → `~/.codex/config.toml.codexgateway-ui.bak.<timestamp>`（timestamp 用 `yyyyMMdd-HHmmss-SSS`）。
2. **原子写入**：写同目录临时文件 `config.toml.codexgateway-ui.tmp` → `fsync` → `rename` → 覆盖原文件。
3. **失败回滚**：任一环节（写 tmp / rename / 文件校验）抛错 → 用备份字节恢复原文件，并向 UI 报错。
4. **写后自检**：`swift TOML` 校验（简单括号/引号配平或调用代码自带解析）；校验失败同样回滚。
5. **token 保护**：任何日志/UI 报错只印 `model_provider` / `model` / 文件路径，**禁止打印 `api_key`/`experimental_bearer_token`/任何 key 值**。

### 读取（供状态卡）
`CodexConfigRoute.read()`：解析顶层 `model_provider`、`model`、`openai_base_url`（含注释态）→ 判定当前线路。同样不读/不回显任何密钥。

**改哪些文件**
- 新增 `CodexGateway/Services/CodexConfigRoute.swift`（行级编辑器 + 备份 + 原子写 + 回滚 + 只读状态）
- 新增 `Tests/CodexGatewayTests/CodexConfigRouteTests.swift`（纯 Foundation，本地可跑，覆盖下节验收）
- `SettingsStore` 不侵入（Route 独立自洽，避免破坏现有 provider/model 流程）。

---

## 5. GitHub Actions 构建 `CodexGateway CN Test`

新增 `.github/workflows/cn-test.yml`（`macos-latest`，官方自带完整 Xcode，无需本机 Xcode）：

```yaml
name: CN Test Build
on:
  workflow_dispatch:
  push: { branches: [ cn-test ] }        # 可选手工触发
jobs:
  build:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Verify full Xcode        # xcodebuild -version（确保 actool/SwiftUIMacros 可用）
      - name: Run unit tests           # make test（含新增 CodexConfigRouteTests）
      - name: zstd regression harness  # 单独 checkout/复制 /tmp harness，跑测试补丁，验证 PASS
      - name: Build CN Test app        # ./scripts/build-macos-app.sh --name "CodexGateway CN Test" --bundle-id com.rimusz.CodexGateway.CNTest
      - name: Ad-hoc / unsigned sign   # codesign -s - （ad-hoc），不做 Developer ID
      - name: Zip artifact             # CodexGateway-CN-Test.zip → actions/upload-artifact
```

产出：`CodexGateway-CN-Test.zip`（内含 `CodexGateway CN Test.app`）作为 workflow artifact。
**不做正式发布签名、不要 Developer ID、不 notarize。**

> 注：macOS runner 上 `make app` 默认生成 `dist/…-macOS.dmg`，CN 版只出 zip（要件只要求 zip）。

---

## 6. zstd compact 修复的并入

- 工作树已含修复代码；IAMPL 阶段直接基于当前工作树继续，**不重复 `git apply`**（避免冲突）。
- 若从 pristine 重来：`git apply codexgateway-zstd-fix.patch`（已验证 PASS）。
- **不改补丁逻辑**。
- harness 回归（R1–R4b）在 CI 中以独立工程承载（见 §5），满足验收 9。

---

## 7. 风险点

| # | 风险 | 缓解 |
|---|---|---|
| R1 | 本机无 Xcode，含 SwiftUI 的编译/`make test` 本地过不了 | 纯 Foundation 逻辑（`CodexConfigRoute`、`AppLanguage` 解析）本地 `swift test`；UI 编译交 CI |
| R2 | bundle id 未改 → 与正式 App 冲突 / 覆盖 | 走 `com.rimusz.CodexGateway.CNTest`，脚本参数化 |
| R3 | `config.toml` 行级修改破坏 TOML 结构 / 注释 | 只改顶层 3 键 + 写后自检 + 回滚；全量单元测试覆盖 |
| R4 | `openai_base_url` 注释/恢复状态与现有 managed block 冲突 | 修改器优先尊重 managed block 内已有写法并保留原文行 |
| R5 | 泄露 token/API key 到日志或 UI | 读取器/编辑器统一走屏蔽；测试断言不输出密钥 |
| R6 | harness 是 `/tmp` 临时工程，CI 无法直接引用 | 把 harness 测试源码作为 fixtures 纳入仓库或独立 CI 步骤生成 |
| R7 | 语言切换时 AppKit 菜单与 SwiftUI 不同步 | 统一走 `NSLocalizedString` + 语言变更通知重建 |
| R8 | CI `make test` 因 SwiftUI 宏在 runner 上失败 | runner 用 `macos-latest`（全新 Xcode）；必要时把 UI 目标从 `swift test` 排除、单测只测纯逻辑层 |
| R9 | 双 APP_NAME（带空格）导致脚本路径/icon 复制出错 | 脚本一律引号包裹，并用 `--bundle-id` 显式传值，CI 步骤单独验证 `.app` 存在及名称 |

---

## 8. 验收映射（源码阶段）

1. 汉化切换正常 → §2 + 手工/CI 冒烟
2. English 正常 → §2
3. OpenAI→Gateway 切换 → §4 单测
4. Gateway→OpenAI 切换 → §4 单测
5. 自动备份 → 断言生成 `config.toml.codexgateway-ui.bak.*`
6. provider 块不变 → 单测断言 `[model_providers.codexgateway]` 原样保留
7. token 不泄露 → 单测断言日志/输出无 key 值
8. TOML 不损坏 → 写后自检 + 单测
9. zstd regression PASS → CI harness R1–R4b
10. git diff 仅预期修改 → 提交前人工核对

---

## 9. 建议实施顺序（确认后）

1. `AppIdentity` + `build-macos-app.sh` 双身份/双 bundle id（最基础，先立隔离）
2. `CodexConfigRoute.swift` + 单测（本地可验证，最敏感先做）
3. `AppLanguage.swift` + Localizable.strings + Settings/StatusBar 接入
4. `RouteSectionView` 接入 Settings
5. `cn-test.yml` workflow + 本地纯逻辑单测跑通
6. 全量验收 + `git diff` 核对