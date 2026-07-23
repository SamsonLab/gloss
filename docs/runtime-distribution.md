# Gloss 与 BabelDOC 发行链路

Gloss 将自维护的 BabelDOC 作为独立 runtime 更新，不再要求用户从系统 `PATH` 安装任意版本。
App 只接受 `SunChJ/BabelDOC` Release 中由 Gloss 发布密钥签名的 manifest。

## BabelDOC runtime manifest

默认更新地址：

| 通道 | Manifest |
| --- | --- |
| stable | `https://github.com/SunChJ/BabelDOC/releases/latest/download/gloss-runtime-manifest.json` |

本轮发行只开放 `stable`。`beta` 与 `nightly` 枚举值为后续兼容而保留，但不会出现在 App
可选通道中，调用 `setChannel` 也会在对应 release alias 与签名产物上线前明确拒绝。

每个 manifest 必须有相邻的 detached Ed25519 签名
`gloss-runtime-manifest.json.sig`。签名覆盖 manifest 文件的原始 bytes；签名文件可以是 64-byte raw
signature 或其 Base64 文本。Gloss 内置并固定 raw 32-byte public key：

```text
0lgbX+CkmBjf4BnH9JO66I7Krd1DYM8lTOjIt+7zWEE=
```

私钥只存放在 BabelDOC 仓库的 GitHub Actions secret，不能提交到任一仓库。签名或 SHA-256
不匹配时，更新会 fail closed，现用 runtime 保持不变。

Manifest schema v1 示例：

```json
{
  "schemaVersion": 1,
  "channel": "stable",
  "version": "0.6.4+gloss.4",
  "releaseTag": "v0.6.4-gloss.4",
  "publishedAt": "2026-07-23T10:16:56Z",
  "minimumGlossVersion": "0.8.0",
  "releaseNotesURL": "https://github.com/SunChJ/BabelDOC/blob/v0.6.4-gloss.4/docs/release-notes/v0.6.4-gloss.4.md",
  "assets": [
    {
      "operatingSystem": "macos",
      "architecture": "arm64",
      "url": "https://github.com/SunChJ/BabelDOC/releases/download/v0.6.4-gloss.4/gloss-babeldoc-0.6.4-gloss.4-macos-arm64.tar.gz",
      "sha256": "8eb8b5b7f629a39715e9e317306861fd1adb6b67b483b7cab89589b986595436",
      "size": 228709309,
      "archiveFormat": "tar.gz",
      "executablePath": "gloss-babeldoc-runtime/gloss-babeldoc"
    }
  ]
}
```

Runtime archive 的入口必须位于 manifest 声明的 `executablePath`，且文件名为
`gloss-babeldoc`。安装器在解包前拒绝绝对路径、`..` 和 Windows drive 路径，在激活前拒绝
符号链接/硬链接并验证可执行权限。下载与解包发生在相同 filesystem 的 staging 目录，完整
校验后才移动到版本目录；`state.json` 使用 atomic replace，因此下载中断或进程崩溃不会切换
active runtime。

## App 内的状态与控制

`BabelDOCRuntimeManager` 是 actor，并暴露：

- `snapshot()` / `snapshots()`：当前、上一版、可用版本、更新通道、pin、操作状态与错误。
- `currentVersion` / `currentExecutableURL`：由 snapshot 提供给 executor 启动逻辑。
- `checkForUpdates()` / `update()`：验证 detached signature 后检查或安装新版本。
- `install(_:)`：显式安装一个已经验证策略的 manifest。
- `pin(version:)`：固定 runtime 版本；其他版本的 manifest 会被拒绝。
- `setChannel(_:)`：切换到已发布通道并清除旧 pin；当前仅允许 stable。
- `rollback()`：原子交换 current/previous，保留一次快速回滚能力。

默认数据目录是：

```text
~/Library/Application Support/Gloss/BabelDOCRuntime/
├── state.json
└── versions/
    ├── 0.6.4+gloss.2-<sha-prefix>/
    └── 0.6.4+gloss.4-<sha-prefix>/
```

测试和受控企业分发可以向 manager 注入 manifest URL、transport 和 Ed25519 public key，不需要
访问公网，也不会降低 production 默认校验。

## Gloss Release

`.github/workflows/release.yml` 在 `v*` tag 上：

1. 分别在 `macos-15` arm64 和 `macos-15-intel` x86_64 runner 构建 `Gloss.app`，并显式使用
   `GLOSS_SIGN_IDENTITY=-` 对 App、helper 与嵌套 extension 做 ad-hoc codesign；不导入 Apple
   证书，也不执行 notarization 或 stapling。
2. 生成 `Gloss-macos-arm64.zip`、`Gloss-macos-x86_64.zip`、`SHA256SUMS` 和包含两个
   architecture asset 的 `gloss-release-manifest.json`。
3. 生成并校验使用 `on_arm` / `on_intel` URL 与 SHA-256 的 `Casks/gloss.rb`。Manifest 和
   Cask 中的下载地址固定指向公开仓库
   `https://github.com/SunChJ/gloss-releases/releases/download/<tag>/`。
4. 始终上传私有主仓中的 Actions artifact，便于内部验证。
5. 仅在 tag 事件中使用跨仓库 token，把 app zip、校验和、manifest 与生成的 Cask 发布到
   公开的 `SunChJ/gloss-releases` GitHub Release。
6. Release 上传成功后，dispatch `SunChJ/homebrew-tap` 的 `update-cask.yml`，由公开 tap
   下载并二次校验 Release，再更新 `Casks/gloss.rb`。

完整 App 会同时检出并构建私有浏览器扩展仓库。Release workflow 使用两个职责分离的凭据：

| Secret | 用途 |
| --- | --- |
| `GLOSS_EXTENSION_SSH_KEY` | 只读检出私有 `SunChJ/personal-immersive-translator` |
| `GLOSS_DISTRIBUTION_TOKEN` | 向公开 binary repo 上传 Release，并 dispatch 公开 tap workflow |

workflow 的第一个 job 始终检查 `GLOSS_EXTENSION_SSH_KEY`；tag 事件还会检查
`GLOSS_DISTRIBUTION_TOKEN`。缺失即 fail closed，不会开始正式构建。手工
`workflow_dispatch` 不走 public publication 路径，因此不需要 distribution token，但仍需
只读 extension deploy key 才能构建完整 App。

### 公开仓库与凭据初始化

公开分发使用两个独立仓库，私有 `SunChJ/gloss` 不承载匿名下载：

- `SunChJ/gloss-releases`：public；初始化 `main` 分支，仅承载发行说明、tag 和二进制 Release
  assets。
- `SunChJ/homebrew-tap`：public；初始化 `main` 分支，包含 `Casks/gloss.rb` 以及
  `.github/workflows/update-cask.yml`。

在 GitHub 创建 fine-grained personal access token，并按下面的最小边界配置：

1. Resource owner 选择 `SunChJ`，Repository access 只选择
   `SunChJ/gloss-releases` 和 `SunChJ/homebrew-tap`。
2. Repository permissions 设置 `Contents: Read and write`，用于在 `gloss-releases`
   创建 tag/Release 和上传 assets。
3. Repository permissions 设置 `Actions: Read and write`，用于 dispatch
   `homebrew-tap/.github/workflows/update-cask.yml`。
4. 将 token 保存为私有 `SunChJ/gloss` 仓库的 Actions secret
   `GLOSS_DISTRIBUTION_TOKEN`。不要把 token 写入 workflow、日志、公开仓库或本地发行产物；
   按 token 到期时间提前轮换。

同一个 fine-grained token 的权限会应用到所选的两个仓库，因此这里使用完成两项跨仓库操作所需
权限的并集。Token 不需要访问私有 `SunChJ/gloss`；workflow 通过该仓库自己的
`GITHUB_TOKEN` 只读检出源码。

为私有 `SunChJ/personal-immersive-translator` 创建独立 Ed25519 SSH key pair，把 public
key 添加为该仓库的 read-only deploy key，把 private key 保存为
`GLOSS_EXTENSION_SSH_KEY`。不要为 deploy key 启用 write access，也不要复用个人 SSH key。
`GLOSS_DISTRIBUTION_TOKEN` 不应访问私有扩展源码。

`homebrew-tap` 的 `update-cask.yml` 必须声明两个 required `workflow_dispatch` inputs：
`release_tag` 和 `release_repository`。它应只接受
`release_repository == "SunChJ/gloss-releases"`，下载
`Gloss-macos-arm64.zip`、`Gloss-macos-x86_64.zip`、`SHA256SUMS` 与 `gloss.rb`，执行
SHA-256 校验并确认 Cask 内的版本、两个 checksum、公开 URL 和安全 `postflight` 后才更新
`Casks/gloss.rb`。若 workflow 通过 PR 更新 `main`，还需在 tap 仓库
Settings → Actions → General
启用 “Allow GitHub Actions to create and approve pull requests”，并给该 workflow
`contents: write`、`pull-requests: write`。

本地生成发行元数据：

```bash
Scripts/build_app.sh
GLOSS_RELEASE_ARCHITECTURE="$(uname -m)" Scripts/package_release.sh

# 收集在两类 Mac 上生成的 zip 后：
Scripts/generate_release_metadata.sh \
  dist/release/Gloss-macos-arm64.zip \
  dist/release/Gloss-macos-x86_64.zip \
  0.8.0 \
  dist/release \
  v0.8.0 \
  SunChJ/gloss-releases
```

## Homebrew 更新

Gloss 主仓不再包含会向自身提交 Cask PR 的 `homebrew-cask.yml`。正式 Release 成功后，它会
运行等价于下面的跨仓库 dispatch：

```bash
gh workflow run update-cask.yml \
  --repo SunChJ/homebrew-tap \
  --ref main \
  -f release_tag=v0.8.0 \
  -f release_repository=SunChJ/gloss-releases
```

公开 tap 合并生成的 Cask 更新后，用户使用标准 tap 名称安装和升级：

```bash
brew tap sunchj/tap
brew install --cask sunchj/tap/gloss
brew update
brew upgrade --cask sunchj/tap/gloss
```

### 正式发行顺序

1. 先发布兼容的 `SunChJ/BabelDOC` signed runtime，并确认 stable manifest 可下载。
2. 合并 Gloss 的发行提交，确认 `Resources/Info.plist` 版本与准备创建的 `v*` tag 完全一致。
3. 确认两个公开仓库、`update-cask.yml`、`GLOSS_EXTENSION_SSH_KEY`、
   `GLOSS_DISTRIBUTION_TOKEN` 和 tap 的 Actions/branch protection 设置均已就绪。
4. 在私有 Gloss 仓库的目标 commit 上创建并推送 tag，例如 `v0.8.0`。
5. 等待 Gloss Release workflow 完成 ad-hoc 签名；workflow 会先创建 draft Release，上传全部
   资产后再发布，最后 dispatch tap 更新。
6. 在 `SunChJ/gloss-releases` 验证两种架构 zip、`SHA256SUMS`、
   `gloss-release-manifest.json` 与 `Casks/gloss.rb` 均存在且 URL 指向该公开 Release。
7. 审阅并合并 `SunChJ/homebrew-tap` 生成的 Cask PR，然后在 arm64 与 x86_64 Mac 上分别执行
   `brew install --cask sunchj/tap/gloss` smoke test。

`SunChJ/gloss-releases` 必须启用 GitHub release immutability。已发布 Release 的 tag 与资产
不可覆盖；相同 tag 的 workflow 重跑会 fail closed。上传中断时 Release 仍保持 draft，
重跑可以修复 draft 资产并重新发布。

如果公开 Release 已成功但 tap dispatch 失败，可以从 `SunChJ/homebrew-tap` Actions 页面手工
运行 `update-cask.yml`，输入相同的 tag 和固定 repository
`SunChJ/gloss-releases`。不要从私有 Gloss Release 或未经 `SHA256SUMS` 验证的临时 URL
生成公开 Cask。

### Ad-hoc 分发的安全取舍

这个渠道刻意不使用 Developer ID Application 证书、Apple notarization 或 stapled ticket：

- macOS 无法把 `Gloss.app` 的签名绑定到经过 Apple 验证的发布者身份，也不会获得 Apple
  notarization 的恶意软件扫描与撤销信号。
- Cask 的下载 SHA-256 和公开 Release 的 `SHA256SUMS` 能证明实际下载内容与 tap 固定的内容
  相同，但它们不能替代发布者身份签名；`gloss-releases`、`homebrew-tap` 或跨仓库 token
  同时失守时，攻击者可能替换二进制与 checksum。
- custom tap 的 `postflight` 按最深层优先顺序分别对 Safari `.appex`、Codex helper、CLI 和
  最外层 `Gloss.app` 执行 `codesign --force --sign -`，不使用可能覆盖嵌套 entitlement 的
  `--deep --sign`；每一步都通过
  `--preserve-metadata=identifier,entitlements,requirements,flags,runtime` 保留已有 metadata，
  并比较签名前后 App 与 `.appex` 的 entitlement bytes。随后只递归删除
  `com.apple.quarantine`、确认该属性已经不存在，最后用
  `codesign --verify --deep --strict` fail closed 验证完整签名。这让正常 Homebrew 安装后的首次
  启动不需要用户绕过 Gatekeeper，但也主动移除了 Gatekeeper 的隔离检查。
- ad-hoc 签名不能完成 Safari App Extension 与宿主 App 的 Apple 身份配对，因此该发行方式不
  承诺 Safari extension 可用；需要 Safari 配对时仍应在本地使用 Apple Development 身份构建。

因此该 Cask 只适用于用户明确信任 `SunChJ/homebrew-tap` 和
`SunChJ/gloss-releases` 的自定义分发场景，不应被描述为 Apple 已签名或已公证的软件。
