<div align="center">
  <img src="Resources/GlossIcon.png" width="144" alt="Gloss 图标">
  <h1>Gloss</h1>
  <p><strong>面向浏览器与保留版式 PDF 的 macOS 原生翻译工具。</strong></p>
  <p>
    <a href="README.md">English</a> ·
    <a href="README.zh-CN.md">简体中文</a>
  </p>
  <p>
    <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&logoColor=white">
    <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
    <a href="LICENSE"><img alt="PolyForm Noncommercial 1.0.0" src="https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-2563EB"></a>
  </p>
</div>

Gloss 是一款围绕完整工作流构建的 macOS 原生翻译应用，而不是互不关联的功能集合。
当前版本聚焦两个场景：浏览器内容翻译，以及保留原始版式的 PDF 翻译。

App 与 `gloss-cli` 共用同一套能力注册表、翻译 Provider、缓存和调度层。你既可以通过
本机已安装并登录 ChatGPT 的 Codex CLI 翻译，也可以通过 `llama.cpp` 将翻译留在本机完成。

## 主要能力

| 工作流 | Gloss 提供的能力 |
| --- | --- |
| 浏览器翻译 | 仅监听本机的鉴权桥接和内置 Chrome 扩展；Apple 签名构建还可以包含 Safari 扩展。 |
| PDF 翻译 | 约 230 MB 的签名 BabelDOC runtime 按需安装，保留文档版式，支持批量队列、更新回滚和安全卸载。 |
| 翻译引擎 | 使用本机已安装的 Codex CLI 登录 ChatGPT，或使用 `llama.cpp` 与 Hy-MT2 在本机翻译。 |
| 自动化 | 通过 `gloss-cli` 查询能力、翻译浏览器文本与 PDF，并执行文本翻译和诊断。 |

Gloss 使用 Swift 开发，通过 Apple Vision 在本机执行 OCR；浏览器桥接只监听
`127.0.0.1`，并使用每台设备独立的随机令牌鉴权。

## 安装

Gloss 要求 **macOS 14 或更高版本**。

```bash
brew install --cask sunchj/tap/gloss
```

可以在 App 内升级，也可以运行：

```bash
brew update
brew upgrade --cask sunchj/tap/gloss
```

Homebrew 版本使用 ad-hoc 签名，并未经过 Apple 公证。Cask 会在本机重新签名、移除
quarantine 属性并验证安装结果。公开二进制和签名更新元数据发布在
[`SunChJ/gloss-releases`](https://github.com/SunChJ/gloss-releases/releases/latest)。

## 快速开始

1. 打开 Gloss；主面板默认显示浏览器翻译状态与扩展入口。
2. 点击右上角设置按钮或按 `⌘,`，选择翻译引擎和 `跟随系统 / 浅色 / 深色` 外观。
3. 使用 GPT 翻译时选择 **登录 ChatGPT**；Gloss 不要求单独提供 API Key。
4. 使用本地翻译时，先运行 `brew install llama.cpp`，再选择 **本地模型**。首次运行会
   下载约 1.1 GB 的量化模型。
5. 使用 Chrome 时，在 Gloss 主面板或设置中选择 **显示扩展**，然后在
   `chrome://extensions` 的开发者模式下加载该目录。
6. 首次使用 PDF 翻译时按需安装组件，再选择或拖入文件并指定输出目录。

Safari 仅在包含 Safari App Extension 和匹配 App Group entitlement 的 Apple 签名构建中
可用。Homebrew 版本会主动隐藏这一入口。

## 命令行

Homebrew Cask 会将 `gloss-cli` 链接到其 `bin` 目录：

```bash
# 查看当前构建包含的能力
gloss-cli capabilities --json

# 翻译其他工具已经提取的网页正文
gloss-cli browser --target 'Chinese (Simplified)' 'Translate this webpage.'

# 翻译一个或多个 PDF
gloss-cli pdf paper-a.pdf paper-b.pdf \
  --output ./translated \
  --target 'Chinese (Simplified)' \
  --mode mono

# 使用本地引擎翻译文本
gloss-cli text --provider llama \
  --target 'Chinese (Simplified)' \
  'Translate locally.'
```

`browser` 可以从参数或 stdin 读取正文，但不会操控浏览器 UI。`pdf` 将进度写入 stderr，
并以 JSON 形式将最终产物路径写入 stdout，适合用于自动化脚本。

## 隐私与安全

- 本地模型模式下，原文和译文都留在设备上。
- OCR 通过 Apple Vision 在本机完成；只有识别后的文字会交给所选翻译引擎。
- 浏览器桥接只监听 localhost，并要求每台设备独立的随机令牌。
- 运行日志不记录原文或译文，并以 `0600` 权限保存在 `~/Library/Logs/Gloss/`。
- BabelDOC 包和 App 更新 manifest 在安装前均会验证签名；发布产物还会固定校验和。

## 开发

开发环境需要 macOS 14+、Xcode Command Line Tools 和 Swift 6。

```bash
swift test --parallel
swift run Gloss
swift run gloss-cli capabilities --json
```

构建可分发的 App：

```bash
./Scripts/build_app.sh
open dist/Gloss.app
```

打包脚本要求在相邻目录中提供配套的浏览器扩展源码，并且默认不再内置 Codex。
请先安装 Codex CLI，或设置 `GLOSS_CODEX_BIN`；
`./Scripts/build_app_without_bundled_codex.sh` 是默认轻量构建的显式入口。扩展源码不在
相邻目录时，可通过 `GLOSS_BROWSER_EXTENSION_SOURCE` 指定其位置。

## 代码结构

| 路径 | 职责 |
| --- | --- |
| `Sources/GlossCore/` | Provider、翻译模型、缓存、调度、BabelDOC、更新与本机桥接 |
| `Sources/GlossOCR/` | Apple Vision OCR 与阅读顺序恢复 |
| `Sources/Gloss/` | macOS App、设置、结果面板、PDF 工作流与浏览器集成 |
| `Sources/GlossCLI/` | 浏览器、PDF 与文本命令 |
| `Sources/GlossUpdateHelper/` | 经过验证的 Homebrew 更新交接 |

发行机制和信任边界参见
[`docs/runtime-distribution.md`](docs/runtime-distribution.md)，各版本的具体变化记录在
[`docs/release-notes/`](docs/release-notes/) 中。

## 许可证

Gloss 以
[PolyForm Noncommercial License 1.0.0](LICENSE)
作为**源码可见（source-available）**软件发布。

你只能在该许可证允许的非商业目的下使用、研究、修改和分发 Gloss。
**未经 SamsonLab 另行书面授权，不得用于商业用途。** 该许可证并非 OSI 认可的开源许可证。

第三方组件与 runtime 依赖继续适用其各自的许可证。
