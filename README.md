# Gloss

Gloss 是一款 macOS 原生、上下文感知的系统级翻译工具：选中任何文本，原地理解、翻译并继续工作。

当前实现已经打通第一条完整链路：

- 监听鼠标选区、已选文本长按和可录制的全局快捷键（默认 `⌃⌥G`）
- 可全局关闭自动出现，或仅在指定 App 中停用；手动快捷键仍然可用
- 提供 App 例外列表，可查看、添加或移除自动出现规则
- 支持登录时启动；辅助功能权限撤销或重新授予后会自动收敛到正确状态
- 在选区附近显示轻量 GlossBar 与不抢焦点的自适应结果卡片；可用 `Esc` 收起
- 内置固定版本的原生 Rust Codex app-server，不依赖 Node、Homebrew、系统 PATH 或外部 Codex CLI
- 使用 Gloss 独立的 Codex 数据目录与 ChatGPT 登录；登录后在后台并行预建翻译 thread 池
- 使用结构化输出、只读沙盒和禁用工具的临时线程
- 译文与原文在同一结果卡片中直接对照，并支持复制译文、替换原文和追加双语
- 提供分开的 macOS 文本与图片“服务”入口，避免被系统归入错误分类
- 可翻译剪贴板图片、交互式截图及系统“服务”传入的图片或图片文件
- 截图写入权限隔离的临时目录并在读取后立即删除，不占用系统剪贴板
- 复制式选区与替换回退会恢复普通剪贴板；遇到密码管理器、临时内容、文件承诺或超大内容时不执行破坏性回退
- 使用 Apple Vision 在本机完成 OCR，只把识别后的文字交给翻译引擎
- 支持目标语言与忠实、自然、技术、学术、字幕风格
- 使用本地语种识别，在源文与主要目标同语种时自动切换到可配置的反向语言
- 内置 16 种常用目标语言，语种识别不会产生模型调用
- 将最近 200 条主动翻译以 `0600` 权限保存在本机，支持搜索、复制、删除、清空和重新翻译；可随时关闭
- 支持本地 TSV 术语表；每次只向模型加入原文实际命中的最多 40 条术语，编辑后自动清除旧缓存
- 缓存重复内容，并合并并发的相同请求
- 默认使用低延迟的 `gpt-5.3-codex-spark`，最多并发执行 3 个独立翻译 turn；每次完成后回滚该 turn，避免跨批上下文累积
- 内置只监听 `127.0.0.1` 的浏览器桥接，与扩展共享同一个翻译代理和缓存
- Chrome 扩展与 Safari Web Extension 均随 `Gloss.app` 打包，共用 WXT 源码
- 使用每机随机令牌鉴权：Chrome 自动注入 App 管理副本，Safari 通过 App Group 安全配对
- 提供 `gloss-cli` 作为脚本与诊断入口

## 运行日志

Gloss 菜单和设置页均提供“查看日志”入口，固定目录为：

```text
~/Library/Logs/Gloss/
├── gloss.log          # 启动、桥接、RPC 与翻译批次耗时；不记录原文或译文
└── codex-stderr.log   # Codex app-server 的原始 stderr
```

两份日志权限均为 `0600`，达到 5 MB 后保留一份 `.1` 轮转文件。也可以直接观察：

```bash
tail -f ~/Library/Logs/Gloss/gloss.log
```

## 前置条件

1. 首次启动时，在 Gloss 设置中点击“登录 ChatGPT”。不需要单独安装 Codex CLI 或 Node.js。
2. 首次使用选区翻译时，在系统设置中允许 Gloss 使用“辅助功能”。
3. Chrome：在 Gloss 设置中点“显示扩展”，从 `chrome://extensions` 加载这个已自动配对的目录。
4. Safari：在 Gloss 设置中点“Safari 设置”，启用随 App 内置的 Gloss Extension。

Gloss 的登录状态和 Codex 配置保存在 `~/Library/Application Support/Gloss/Codex/`，不会修改系统 Codex CLI 的数据。

系统“服务”入口默认由 macOS 管理。可在 Gloss 设置中打开“键盘快捷键”，再到“服务”里启用文本或图片翻译入口。

## 开发

```bash
swift test
swift run Gloss
```

直接验证翻译后端：

```bash
swift run gloss-cli --target 'Chinese (Simplified)' 'Translate this text.'
printf 'Translate stdin.\n' | swift run gloss-cli --target Japanese
swift run gloss-cli --kind ocr 'Text recognized from an image.'
```

开发时可以覆盖原生 app-server 和独立数据目录：

```bash
GLOSS_CODEX_APP_SERVER_BIN=/path/to/codex-app-server \
GLOSS_CODEX_HOME="$HOME/Library/Application Support/Gloss/Codex" \
GLOSS_CODEX_MODEL=gpt-5.3-codex-spark \
GLOSS_CODEX_MAX_CONCURRENCY=3 \
swift run gloss-cli 'Hello from Gloss.'
```

`GLOSS_CODEX_BIN` 仍保留为外部 Codex CLI 的开发兼容选项；产品构建始终优先使用 App 内置 runtime。

未设置时使用 `gpt-5.3-codex-spark`；并发数默认 3，可配置范围为 1–8。

## 打包

```bash
./Scripts/build_app.sh
open dist/Gloss.app
```

构建脚本会按 `CodexRuntime.lock` 下载并校验固定版本的官方 Rust app-server，把它与许可证一起嵌入 App；随后在相邻的 `personal-immersive-translator` 仓库中生成 Chrome/Safari 产物，并把 Chrome 资源与 Safari `.appex` 嵌入 App。结果位于 `dist/Gloss.app`。脚本会优先使用钥匙串中的第一个 Apple Development 身份；没有可用证书时退回临时签名，此时 Safari 配对不可用。正式分发前需要换成 Developer ID 签名和公证。

需要稳定的本机开发签名时，可显式传入钥匙串中的证书：

```bash
GLOSS_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./Scripts/build_app.sh
```

正式分发时使用 `Developer ID Application` 证书执行同一命令；脚本会自动启用 Hardened Runtime 与可信时间戳。随后仍需用 Apple `notarytool` 公证并对 App 执行 `stapler staple`。

## 代码结构

```text
Sources/GlossCore/   Codex 客户端、翻译模型、缓存与并发合并
Sources/GlossOCR/    本地 Vision OCR 与版面阅读顺序恢复
Sources/Gloss/       macOS 选区、图片、截图、结果面板、文本替换与浏览器桥接
Sources/GlossCLI/    薄命令行入口
```
