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
- 可在设置中即时切换 GPT 订阅与本地 `llama.cpp` provider；GPT 可配置 model 和 reasoning
- 本地选项使用 `Hy-MT2-1.8B-GGUF:Q4_K_M`，通过 Metal 运行，原文和译文都留在设备上
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

1. GPT 订阅：首次启动时，在 Gloss 设置中点击“登录 ChatGPT”。默认构建不需要单独安装 Codex CLI 或 Node.js；CLI 构建需要用户已安装支持 `app-server` 的 Codex CLI。
2. 本地模型：安装 `llama.cpp`（`brew install llama.cpp`），然后在翻译引擎中选择“本地模型”。首次启动会从 Hugging Face 下载约 1.1 GB 的 Q4 模型。
3. 首次使用选区翻译时，在系统设置中允许 Gloss 使用“辅助功能”。
4. Chrome：在 Gloss 设置中点“显示扩展”，从 `chrome://extensions` 加载这个已自动配对的目录。
5. Safari：在 Gloss 设置中点“Safari 设置”，启用随 App 内置的 Gloss Extension。

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
swift run gloss-cli --provider llama --target 'Chinese (Simplified)' 'Translate locally.'
swift run gloss-cli --provider codex --model gpt-5.3-codex-spark --reasoning low 'Translate quickly.'
printf 'Translate stdin.\n' | swift run gloss-cli --target Japanese
swift run gloss-cli --kind ocr 'Text recognized from an image.'
```

开发时可以覆盖原生 app-server 和独立数据目录：

```bash
GLOSS_CODEX_APP_SERVER_BIN=/path/to/codex-app-server \
GLOSS_CODEX_HOME="$HOME/Library/Application Support/Gloss/Codex" \
GLOSS_CODEX_MODEL=gpt-5.3-codex-spark \
GLOSS_CODEX_REASONING_EFFORT=low \
GLOSS_CODEX_MAX_CONCURRENCY=3 \
GLOSS_CODEX_BACKGROUND_CONCURRENCY=2 \
swift run gloss-cli 'Hello from Gloss.'
```

`GLOSS_CODEX_BIN` 可覆盖外部 Codex CLI 路径。默认构建优先使用 App 内置 runtime；CLI 构建只使用用户安装的 Codex CLI。

未设置时使用 `gpt-5.3-codex-spark`；并发数默认 3，可配置范围为 1–8。Gloss 默认最多
同时运行 2 个后台 PDF turn，保留一个 thread 给交互翻译或 Spark 长尾竞速。后台 PDF
turn 使用 Spark 支持的最低档 `low` reasoning。BabelDOC 默认用 qps 8 提前抓取段落，但模型侧仍严格限制为
2 路；相邻请求会合并为最多 12 项、1,800 字符的有界批次。模型在 3 秒仍未开始
响应时会记录慢请求；只有中心和 BabelDOC 上游的真实队列都排空，才会在空闲 thread 上
发起 tail hedge，否则跳过竞速。没有统一队列状态的独立 Codex client 仍使用 8 秒阈值。每个 thread 默认完成
10 次成功翻译后无中断轮换。可分别使用 `GLOSS_CODEX_DOCUMENT_REASONING_EFFORT`、
`GLOSS_CODEX_MODEL_WAIT_HEDGE_SECONDS` 和 `GLOSS_CODEX_THREAD_ROTATION_TURNS` 覆盖这些值，
后两项设为 `off` 可关闭对应机制。
Spark 当前拒绝 `minimal` reasoning，PDF 翻译可用的最低档是 `low`；不要将
`GLOSS_CODEX_DOCUMENT_REASONING_EFFORT` 配置为 `minimal`。

批处理实验参数可通过 `GLOSS_BABELDOC_BATCH_ITEMS`、`GLOSS_BABELDOC_BATCH_CHARACTERS`、
`GLOSS_BABELDOC_MODEL_CONCURRENCY`、`GLOSS_BABELDOC_FILL_DELAY_MS` 和
`GLOSS_BABELDOC_REFILL_DELAY_MS` 覆盖。默认值分别为 `12`、`1800`、`2`、`25` 和 `0`；
提高真实模型并发会占用额外 Spark 额度，通常不如增加上游预取和合批稳定。
`GLOSS_BABELDOC_SKIP_CLEAN=1`、`GLOSS_BABELDOC_DISABLE_SAME_TEXT_FALLBACK=1`
和 `GLOSS_BABELDOC_IGNORE_CACHE=1` 分别用于验证快速 PDF 保存、关闭同文重译和无缓存基准；
它们默认关闭，确认输出兼容性和翻译完整性后再考虑提升为默认行为。

打开 PDF 翻译模块会立即启动仅监听本机回环地址的 DocLayout 服务，并在窗口存续期间保持模型
常驻；关闭模块后服务随即停止，避免 App 空闲时长期占用约 500–600 MB 内存。窗口支持按钮选择、
Finder 多文件打开和直接拖拽多个 PDF，任务去重后进入批量队列。文档按队列顺序逐个处理，复用
同一版面服务，避免并行启动多个 BabelDOC 进程造成内存峰值。进度展示会将服务启动、版面解析、
模型等待、排版与保存拆成独立状态。

调度：网页、选词、字幕、OCR 和 BabelDOC 的真实 cache miss 统一进入
`TranslationDispatchCenter`。上游 qps 只控制预取和入队；派发中心按优先级和 FIFO 派发，
总并发最多 3、后台最多 2，并统一处理取消和状态快照。BabelDOC 尚未派发的条目也汇总进
同一状态；Codex 只有在中心和上游真实队列都排空时才允许 tail hedge。第三条 thread 因此
默认保留给交互，provider 内部调度暂时作为执行器安全网保留。

本地 provider 默认查找 App 内的 `llama-server` helper、`GLOSS_LLAMA_SERVER_BIN`、`PATH`，以及 Homebrew 常用路径。模型可通过 `GLOSS_LLAMA_MODEL` 覆盖为 Hugging Face GGUF repo 或本地 `.gguf` 文件：

```bash
GLOSS_LLAMA_SERVER_BIN=/opt/homebrew/bin/llama-server \
GLOSS_LLAMA_MODEL=tencent/Hy-MT2-1.8B-GGUF:Q4_K_M \
swift run gloss-cli --provider llama 'Hello from local Gloss.'
```

## 打包

```bash
./Scripts/build_app.sh
open dist/Gloss.app
```

构建脚本会按 `CodexRuntime.lock` 下载并校验固定版本的官方 Rust app-server，把它与许可证一起嵌入 App；本地 provider 当前复用系统安装的 `llama-server`。随后脚本在相邻的 `personal-immersive-translator` 仓库中生成 Chrome/Safari 产物，并把 Chrome 资源与 Safari `.appex` 嵌入 App。结果位于 `dist/Gloss.app`。脚本默认使用 `-` 做 ad-hoc codesign；这种签名没有 Apple 开发者身份，Safari 配对不可用。

如果不希望下载或嵌入固定 Rust app-server，可构建依赖用户 Codex CLI 的轻量版本：

```bash
./Scripts/build_app_with_codex_cli.sh
```

该脚本会先确认当前环境中的 `codex app-server` 可用，但不会把 Codex runtime、许可证或版本锁文件放入 App。运行时 Gloss 会查找 `GLOSS_CODEX_BIN`、`PATH`、Homebrew 与常用本地安装路径，并执行 `codex app-server --listen stdio://`。进程与 thread 仍统一经过 `CodexAppServerClient`，因此会复用相同的静态模型目录、隔离工作目录和 MCP/skills/tools 禁用配置，不会退回较慢的默认启动方式。

本机调试 Safari 配对时，可显式传入钥匙串中的 Apple Development 证书：

```bash
GLOSS_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./Scripts/build_app.sh
```

当前公开 Homebrew 发行也明确使用 ad-hoc 签名，不要求 Developer ID 或 Apple 公证。

### BabelDOC runtime 更新

Gloss 可以管理来自 `SunChJ/BabelDOC` GitHub Releases 的固定版本 runtime。更新 manifest 使用
内置 Ed25519 public key 验证 detached signature，runtime archive 再做 SHA-256 校验；签名或
校验失败不会替换当前版本。安装器当前开放 stable 通道，并支持版本 pin 和一键 rollback；
beta、nightly 会在对应的已签名 release alias 上线后再开放。安装过程通过 staging directory 与
atomic state file 防止半安装状态。完整 manifest schema、安全边界和发布 secret 见
[Gloss 与 BabelDOC 发行链路](docs/runtime-distribution.md)。

### GitHub Release 与 Homebrew

推送与 `Resources/Info.plist` 一致的 `v*` tag 会运行 Release workflow，产出
arm64 与 x86_64 两套 `Gloss.app` zip、`SHA256SUMS`、release manifest 和带
`on_arm` / `on_intel` 校验的 Homebrew cask。私有 `SunChJ/gloss` 只负责构建；ad-hoc
签名后的资产发布到公开 `SunChJ/gloss-releases`，随后自动 dispatch
`SunChJ/homebrew-tap` 更新 Cask。下载 URL 不会指向私有主仓。

首次安装以及后续升级为：

```bash
brew tap sunchj/tap
brew install --cask sunchj/tap/gloss
brew update
brew upgrade --cask sunchj/tap/gloss
```

Release workflow 使用只读 `GLOSS_EXTENSION_SSH_KEY` 检出私有浏览器扩展；正式 tag 另外
要求跨仓库 `GLOSS_DISTRIBUTION_TOKEN`。缺失时 workflow 会在构建和上传前 fail closed。
手工 workflow 不发布，但仍需要 extension deploy key 才能生成完整 App artifact。
Cask 的 `postflight` 会重新 ad-hoc 签名、移除 quarantine 并验证签名，让安装后启动不弹
Gatekeeper 交互；这也意味着 macOS 无法验证 Apple 开发者身份或公证票据。公开仓库初始化、
fine-grained token 权限、完整安全取舍、发行顺序与恢复步骤见
[发行文档](docs/runtime-distribution.md)。

## 代码结构

```text
Sources/GlossCore/   Codex/llama 客户端、provider 路由、翻译模型、缓存与并发合并
Sources/GlossOCR/    本地 Vision OCR 与版面阅读顺序恢复
Sources/Gloss/       macOS 选区、图片、截图、结果面板、文本替换与浏览器桥接
Sources/GlossCLI/    薄命令行入口
```
