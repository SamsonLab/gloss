import Foundation

struct PDFRuntimeReadyInfo: Equatable {
    let endpoint: String
    let processIdentifier: Int32
    let version: String
    let executablePath: String?
}

enum PDFRuntimeDashboardAction: Equatable {
    case install
    case start
    case update
    case cancel
    case reconnect
    case retry
    case rollback
    case uninstall
}

enum PDFRuntimeDashboardState: Equatable {
    case checking
    case notInstalled
    case installing(version: String?, progress: Int?)
    case starting(version: String)
    case ready(PDFRuntimeReadyInfo)
    case translating(PDFRuntimeReadyInfo, fileName: String, progress: Int?)
    case updateAvailable(PDFRuntimeReadyInfo, availableVersion: String)
    case reconnecting(previousProcessIdentifier: Int32?)
    case stopping(previousProcessIdentifier: Int32?)
    case uninstalling
    case failed(message: String, installedVersion: String?, canRollback: Bool)
    case stopped(installedVersion: String?, canRollback: Bool)

    var isReady: Bool {
        switch self {
        case .ready, .translating, .updateAvailable:
            true
        default:
            false
        }
    }

    var hasInstalledRuntime: Bool {
        switch self {
        case .ready, .translating, .updateAvailable, .starting, .reconnecting,
            .stopping, .uninstalling:
            true
        case .failed(_, let installedVersion, _), .stopped(let installedVersion, _):
            installedVersion != nil
        case .checking, .notInstalled, .installing:
            false
        }
    }

    var canRequestUninstall: Bool {
        switch self {
        case .ready, .updateAvailable:
            true
        case .failed(_, let installedVersion, _), .stopped(let installedVersion, _):
            installedVersion != nil
        default:
            false
        }
    }

    var action: PDFRuntimeDashboardAction? {
        switch self {
        case .checking, .installing, .starting, .reconnecting, .stopping, .uninstalling:
            nil
        case .notInstalled:
            .install
        case .ready:
            .reconnect
        case .translating:
            .cancel
        case .updateAvailable:
            .update
        case .failed(_, let installedVersion, let canRollback):
            if canRollback {
                .rollback
            } else if installedVersion != nil {
                .reconnect
            } else {
                .retry
            }
        case .stopped(let installedVersion, let canRollback):
            if installedVersion != nil {
                .start
            } else if canRollback {
                .rollback
            } else {
                .install
            }
        }
    }

    var presentation: PDFRuntimeDashboardPresentation {
        switch self {
        case .checking:
            return PDFRuntimeDashboardPresentation(
                headline: "正在检查 PDF 运行时…",
                detail: "正在验证已安装版本与残留进程",
                path: nil,
                tone: .neutral,
                actionTitle: "正在检查…",
                actionEnabled: false,
                actionIsDestructive: false,
                showsProgress: true
            )
        case .notInstalled:
            return PDFRuntimeDashboardPresentation(
                headline: "尚未安装 PDF 运行时",
                detail: "Gloss 可以自动安装经过校验的 BabelDOC 运行时",
                path: nil,
                tone: .warning,
                actionTitle: "安装",
                actionEnabled: true,
                actionIsDestructive: false,
                showsProgress: false
            )
        case .installing(let version, let progress):
            let versionText = version.map { " \($0)" } ?? ""
            let progressText = progress.map { " · \($0)%" } ?? ""
            return PDFRuntimeDashboardPresentation(
                headline: "正在安装\(versionText)…",
                detail: "下载、校验并原子切换运行时\(progressText)",
                path: nil,
                tone: .neutral,
                actionTitle: "正在安装…",
                actionEnabled: false,
                actionIsDestructive: false,
                showsProgress: true
            )
        case .starting(let version):
            return PDFRuntimeDashboardPresentation(
                headline: "正在启动 PDF 服务…",
                detail: "BabelDOC \(version) · 正在验证身份与健康状态",
                path: nil,
                tone: .neutral,
                actionTitle: "正在连接…",
                actionEnabled: false,
                actionIsDestructive: false,
                showsProgress: true
            )
        case .ready(let info):
            return readyPresentation(
                info,
                headline: "PDF 服务已就绪",
                detailSuffix: nil,
                tone: .positive,
                actionTitle: "重新连接",
                actionIsDestructive: false,
                showsProgress: false
            )
        case .translating(let info, let fileName, let progress):
            let progressText = progress.map { " · \($0)%" } ?? ""
            return readyPresentation(
                info,
                headline: "正在翻译 \(fileName)",
                detailSuffix: "任务运行中\(progressText)",
                tone: .positive,
                actionTitle: "停止任务",
                actionIsDestructive: true,
                showsProgress: true
            )
        case .updateAvailable(let info, let availableVersion):
            return readyPresentation(
                info,
                headline: "PDF 运行时可更新",
                detailSuffix: "可升级到 \(availableVersion)",
                tone: .warning,
                actionTitle: "更新",
                actionIsDestructive: false,
                showsProgress: false
            )
        case .reconnecting(let previousProcessIdentifier):
            return PDFRuntimeDashboardPresentation(
                headline: "正在重新连接 PDF 服务…",
                detail: previousProcessIdentifier.map {
                    "正在验证并清理旧进程 PID \($0)"
                } ?? "正在验证残留进程并重新启动",
                path: nil,
                tone: .warning,
                actionTitle: "正在重连…",
                actionEnabled: false,
                actionIsDestructive: false,
                showsProgress: true
            )
        case .stopping(let previousProcessIdentifier):
            return PDFRuntimeDashboardPresentation(
                headline: "正在停止 PDF 服务…",
                detail: previousProcessIdentifier.map {
                    "正在等待 PID \($0) 安全退出"
                } ?? "正在取消任务并释放运行时资源",
                path: nil,
                tone: .neutral,
                actionTitle: "正在停止…",
                actionEnabled: false,
                actionIsDestructive: false,
                showsProgress: true
            )
        case .uninstalling:
            return PDFRuntimeDashboardPresentation(
                headline: "正在卸载 PDF 组件…",
                detail: "正在安全停止服务并清理运行时、历史版本与缓存",
                path: nil,
                tone: .warning,
                actionTitle: "正在卸载…",
                actionEnabled: false,
                actionIsDestructive: true,
                showsProgress: true
            )
        case .failed(let message, let installedVersion, let canRollback):
            let versionText = installedVersion.map { " · 已安装 \($0)" } ?? ""
            let actionTitle =
                if canRollback {
                    "回滚"
                } else if installedVersion != nil {
                    "重新连接"
                } else {
                    "重试"
                }
            return PDFRuntimeDashboardPresentation(
                headline: "PDF 服务不可用",
                detail: "\(message)\(versionText)",
                path: nil,
                tone: .negative,
                actionTitle: actionTitle,
                actionEnabled: true,
                actionIsDestructive: false,
                showsProgress: false
            )
        case .stopped(let installedVersion, let canRollback):
            let detail: String
            let actionTitle: String
            if let installedVersion {
                detail = "已安装 BabelDOC \(installedVersion)"
                actionTitle = "启动"
            } else if canRollback {
                detail = "当前版本不可用，可以恢复上一版本"
                actionTitle = "回滚"
            } else {
                detail = "安装经过校验的运行时后即可翻译 PDF"
                actionTitle = "安装"
            }
            return PDFRuntimeDashboardPresentation(
                headline: "PDF 服务未启动",
                detail: detail,
                path: nil,
                tone: .neutral,
                actionTitle: actionTitle,
                actionEnabled: true,
                actionIsDestructive: false,
                showsProgress: false
            )
        }
    }

    private func readyPresentation(
        _ info: PDFRuntimeReadyInfo,
        headline: String,
        detailSuffix: String?,
        tone: PDFRuntimeDashboardPresentation.Tone,
        actionTitle: String,
        actionIsDestructive: Bool,
        showsProgress: Bool
    ) -> PDFRuntimeDashboardPresentation {
        var parts = [
            info.endpoint,
            "PID \(info.processIdentifier)",
            "BabelDOC \(info.version)",
        ]
        if let detailSuffix {
            parts.append(detailSuffix)
        }
        return PDFRuntimeDashboardPresentation(
            headline: headline,
            detail: parts.joined(separator: " · "),
            path: info.executablePath,
            tone: tone,
            actionTitle: actionTitle,
            actionEnabled: true,
            actionIsDestructive: actionIsDestructive,
            showsProgress: showsProgress
        )
    }
}

struct PDFRuntimeDashboardPresentation: Equatable {
    enum Tone: Equatable {
        case neutral
        case positive
        case warning
        case negative
    }

    let headline: String
    let detail: String
    let path: String?
    let tone: Tone
    let actionTitle: String
    let actionEnabled: Bool
    let actionIsDestructive: Bool
    let showsProgress: Bool
}
