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
  "version": "0.6.4+gloss.3",
  "releaseTag": "v0.6.4-gloss.3",
  "publishedAt": "2026-07-22T00:00:00Z",
  "minimumGlossVersion": "0.8.0",
  "releaseNotesURL": "https://github.com/SunChJ/BabelDOC/releases/tag/v0.6.4-gloss.3",
  "assets": [
    {
      "operatingSystem": "macos",
      "architecture": "arm64",
      "url": "https://github.com/SunChJ/BabelDOC/releases/download/v0.6.4-gloss.3/gloss-babeldoc-macos-arm64.tar.gz",
      "sha256": "64-character-lowercase-hex",
      "size": 123456,
      "archiveFormat": "tar.gz",
      "executablePath": "gloss-babeldoc"
    }
  ]
}
```

Runtime archive 的入口必须命名为 `gloss-babeldoc`。安装器在解包前拒绝绝对路径、`..` 和
Windows drive 路径，在激活前拒绝符号链接/硬链接并验证可执行权限。下载与解包发生在相同
filesystem 的 staging 目录，完整校验后才移动到版本目录；`state.json` 使用 atomic replace，
因此下载中断或进程崩溃不会切换 active runtime。

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
    └── 0.6.4+gloss.3-<sha-prefix>/
```

测试和受控企业分发可以向 manager 注入 manifest URL、transport 和 Ed25519 public key，不需要
访问公网，也不会降低 production 默认校验。

## Gloss Release

`.github/workflows/release.yml` 在 `v*` tag 上：

1. 分别在 `macos-15` arm64 和 `macos-15-intel` x86_64 runner 构建 `Gloss.app`；tag 发行强制
   Developer ID 签名、公证与 stapling。
2. 生成 `Gloss-macos-arm64.zip`、`Gloss-macos-x86_64.zip`、`SHA256SUMS` 和包含两个
   architecture asset 的 `gloss-release-manifest.json`。
3. 生成并校验使用 `on_arm` / `on_intel` URL 与 SHA-256 的 `Casks/gloss.rb`。
4. 上传 Actions artifact 与 GitHub Release assets。
5. 启动 Homebrew cask 更新 workflow。

完整 App 会同时检出并构建浏览器扩展仓库。正式 tag 发行必须配置以下签名和公证 secrets：

| Secret | 用途 |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Base64 编码的 `.p12` |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | `.p12` 密码 |
| `DEVELOPER_ID_APPLICATION` | `Developer ID Application: ...` identity |
| `RELEASE_KEYCHAIN_PASSWORD` | 临时 CI keychain 密码 |
| `APPLE_NOTARY_APPLE_ID` | 公证 Apple ID |
| `APPLE_NOTARY_PASSWORD` | App-specific password |
| `APPLE_TEAM_ID` | Apple Developer Team ID |

tag workflow 在任一签名或公证 secret 缺失时 fail closed，不会上传 public GitHub Release 或
启动 Homebrew 更新。手工 `workflow_dispatch` 可以在没有 secrets 时生成仅供内部验证的
ad-hoc artifact，但不会发布。

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
  v0.8.0
```

## Homebrew 更新

`homebrew-cask.yml` 从已发布 Release 重新下载两种架构的 app zip，先按 `SHA256SUMS` 校验，
再生成 `Casks/gloss.rb` 并向本仓库 `main` 提交 PR。它不依赖尚不存在的外部 tap，也不会绕过
branch protection。仓库需要启用 GitHub Actions 的“Allow GitHub Actions to create and
approve pull requests”；若策略不允许，workflow artifact 中仍会保留已经校验的 cask，维护者
可以手工提交。

当前 `SunChJ/gloss` 是 private repository，因此匿名 Homebrew 安装尚未闭环：GitHub private
Release 的 app zip 不能作为公共 cask 下载地址。要向外部分发，必须先将仓库和 binary
Release 设为 public，或把两种架构的 zip 发布到稳定的公共 HTTPS host 并让 cask generator 使用
`GLOSS_CASK_DOWNLOAD_BASE_URL=https://downloads.example.com/gloss/v0.8.0` 指向该目录。手工
运行 Homebrew workflow 时也可以填写 `download_base_url`。完成其中一项后，本仓库才能作为
自定义 tap：

```bash
brew tap sunchj/gloss https://github.com/SunChJ/gloss
brew install --cask sunchj/gloss/gloss
brew update
brew upgrade --cask gloss
```

每次 Gloss Release 都会自动生成并发起 cask 更新；失败时也可从 Actions 手工运行
“Update Homebrew cask”并传入已经发布的 tag。这个自动化完成的是可发布 cask 的生成与校验，
不等同于当前 private repository 已经提供匿名 Homebrew 更新。
