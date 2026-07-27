import Foundation
import GlossCore

enum AppUpdateDelivery: Equatable {
    case homebrew(GlossHomebrewInstallation)
    case releasePage
}

enum AppUpdateDashboardAction: Equatable {
    case check
    case install
    case openReleasePage
}

enum AppUpdateDashboardState: Equatable {
    case unavailable(currentVersion: String, reason: String)
    case idle(currentVersion: String)
    case checking(currentVersion: String)
    case upToDate(currentVersion: String, latestVersion: String)
    case updateAvailable(
        GlossAppUpdateAvailability,
        delivery: AppUpdateDelivery
    )
    case blockedByBusinessTask(
        GlossAppUpdateAvailability,
        installation: GlossHomebrewInstallation
    )
    case preparingInstall(version: String)
    case failed(currentVersion: String, message: String)

    static func fromHomebrewResult(
        _ result: GlossHomebrewUpgradeResult,
        currentVersion: String
    ) -> Self {
        switch result.outcome {
        case .succeeded:
            return .upToDate(
                currentVersion: currentVersion,
                latestVersion:
                    result.installedVersion ?? result.expectedVersion
            )
        case .failed:
            let baseMessage =
                result.message
                ?? "Homebrew 更新未完成（\(result.errorCode ?? "未知错误")）"
            let recoveryDetail =
                if result.recoveredPreviousInstallation {
                    " 已恢复上一版本。"
                } else if let recoveryError = result.recoveryError {
                    " 恢复失败：\(recoveryError)"
                } else {
                    ""
                }
            return .failed(
                currentVersion: currentVersion,
                message: baseMessage + recoveryDetail
            )
        }
    }

    var action: AppUpdateDashboardAction? {
        switch self {
        case .unavailable, .checking, .preparingInstall:
            nil
        case .idle, .upToDate, .failed:
            .check
        case .updateAvailable(_, let delivery):
            switch delivery {
            case .homebrew:
                .install
            case .releasePage:
                .openReleasePage
            }
        case .blockedByBusinessTask:
            .install
        }
    }

    var presentation: AppUpdateDashboardPresentation {
        switch self {
        case .unavailable(let currentVersion, let reason):
            AppUpdateDashboardPresentation(
                headline: "应用更新不可用",
                detail: "Gloss \(currentVersion) · \(reason)",
                tone: .neutral,
                actionTitle: "不可用",
                actionEnabled: false,
                showsProgress: false
            )
        case .idle(let currentVersion):
            AppUpdateDashboardPresentation(
                headline: "自动检查应用更新",
                detail: "Gloss \(currentVersion) · 每 24 小时后台检查一次",
                tone: .neutral,
                actionTitle: "检查更新",
                actionEnabled: true,
                showsProgress: false
            )
        case .checking(let currentVersion):
            AppUpdateDashboardPresentation(
                headline: "正在检查应用更新…",
                detail: "当前版本 Gloss \(currentVersion)",
                tone: .neutral,
                actionTitle: "正在检查…",
                actionEnabled: false,
                showsProgress: true
            )
        case .upToDate(let currentVersion, let latestVersion):
            AppUpdateDashboardPresentation(
                headline: "Gloss 已是最新版本",
                detail: "当前 \(currentVersion) · 最新 \(latestVersion)",
                tone: .positive,
                actionTitle: "再次检查",
                actionEnabled: true,
                showsProgress: false
            )
        case .updateAvailable(let update, let delivery):
            switch delivery {
            case .homebrew:
                AppUpdateDashboardPresentation(
                    headline: "Gloss \(update.version) 可用",
                    detail: "由 Homebrew 安全升级，完成后自动重新启动",
                    tone: .warning,
                    actionTitle: "更新并重新启动",
                    actionEnabled: true,
                    showsProgress: false
                )
            case .releasePage:
                AppUpdateDashboardPresentation(
                    headline: "Gloss \(update.version) 可用",
                    detail: "当前 App 不是由 sunchj/tap/gloss 管理",
                    tone: .warning,
                    actionTitle: "查看下载",
                    actionEnabled: true,
                    showsProgress: false
                )
            }
        case .blockedByBusinessTask(let update, _):
            AppUpdateDashboardPresentation(
                headline: "等待当前翻译任务完成",
                detail: "完成当前任务后即可安装 Gloss \(update.version)",
                tone: .warning,
                actionTitle: "重试更新",
                actionEnabled: true,
                showsProgress: false
            )
        case .preparingInstall(let version):
            AppUpdateDashboardPresentation(
                headline: "正在准备更新到 Gloss \(version)…",
                detail: "Gloss 即将退出；Homebrew 完成升级后会自动重新启动",
                tone: .neutral,
                actionTitle: "正在准备…",
                actionEnabled: false,
                showsProgress: true
            )
        case .failed(let currentVersion, let message):
            AppUpdateDashboardPresentation(
                headline: "应用更新失败",
                detail: "Gloss \(currentVersion) · \(message)",
                tone: .negative,
                actionTitle: "重试",
                actionEnabled: true,
                showsProgress: false
            )
        }
    }

    var menuPresentation: AppUpdateMenuPresentation {
        switch self {
        case .unavailable:
            return AppUpdateMenuPresentation(
                title: "检查更新不可用",
                isEnabled: false
            )
        case .idle, .upToDate:
            return AppUpdateMenuPresentation(
                title: "检查更新…",
                isEnabled: true
            )
        case .checking:
            return AppUpdateMenuPresentation(
                title: "正在检查更新…",
                isEnabled: false
            )
        case .updateAvailable(let update, let delivery):
            let title =
                switch delivery {
                case .homebrew:
                    "更新 Gloss 到 \(update.version)…"
                case .releasePage:
                    "下载 Gloss \(update.version)…"
                }
            return AppUpdateMenuPresentation(title: title, isEnabled: true)
        case .blockedByBusinessTask(let update, _):
            return AppUpdateMenuPresentation(
                title: "完成当前任务后更新到 \(update.version)…",
                isEnabled: true
            )
        case .preparingInstall:
            return AppUpdateMenuPresentation(
                title: "正在准备更新…",
                isEnabled: false
            )
        case .failed:
            return AppUpdateMenuPresentation(
                title: "重试检查更新…",
                isEnabled: true
            )
        }
    }
}

struct AppUpdateDashboardPresentation: Equatable {
    enum Tone: Equatable {
        case neutral
        case positive
        case warning
        case negative
    }

    let headline: String
    let detail: String
    let tone: Tone
    let actionTitle: String
    let actionEnabled: Bool
    let showsProgress: Bool
}

struct AppUpdateMenuPresentation: Equatable {
    let title: String
    let isEnabled: Bool
}
