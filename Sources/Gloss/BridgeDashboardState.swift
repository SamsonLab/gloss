import Foundation

struct BridgeReadyInfo: Equatable {
    let endpoint: String
    let processIdentifier: pid_t
    let version: String
    let executablePath: String?
}

enum BridgeDashboardState: Equatable {
    case inspecting
    case reclaiming(BridgePortOccupant)
    case starting
    case ready(BridgeReadyInfo)
    case occupied(BridgePortOccupant)
    case failed(String)
    case stopped

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var occupant: BridgePortOccupant? {
        switch self {
        case .reclaiming(let occupant), .occupied(let occupant):
            occupant
        default:
            nil
        }
    }

    var presentation: BridgeDashboardPresentation {
        switch self {
        case .inspecting:
            return BridgeDashboardPresentation(
                headline: "正在检查本地连接…",
                detail: "127.0.0.1:8787",
                path: nil,
                tone: .neutral,
                actionTitle: "正在检查…",
                actionEnabled: false,
                showsProgress: true
            )
        case .reclaiming(let occupant):
            return BridgeDashboardPresentation(
                headline: occupant.canAutomaticallyTerminate
                    ? "正在关闭旧 Gloss…"
                    : "正在释放本地端口…",
                detail: occupantSummary(occupant),
                path: occupant.executablePath,
                tone: .warning,
                actionTitle: "正在重连…",
                actionEnabled: false,
                showsProgress: true
            )
        case .starting:
            return BridgeDashboardPresentation(
                headline: "正在启动本地桥接…",
                detail: "127.0.0.1:8787",
                path: nil,
                tone: .neutral,
                actionTitle: "正在连接…",
                actionEnabled: false,
                showsProgress: true
            )
        case .ready(let info):
            return BridgeDashboardPresentation(
                headline: "已连接",
                detail: "\(info.endpoint) · PID \(info.processIdentifier) · Gloss \(info.version)",
                path: info.executablePath,
                tone: .positive,
                actionTitle: "重新连接",
                actionEnabled: true,
                showsProgress: false
            )
        case .occupied(let occupant):
            let headline =
                if occupant.canAutomaticallyTerminate {
                    "旧 Gloss 占用了端口"
                } else if occupant.identityMatchesGloss {
                    "另一个 Gloss 正在运行"
                } else {
                    "端口被其他进程占用"
                }
            return BridgeDashboardPresentation(
                headline: headline,
                detail: occupantSummary(occupant),
                path: occupant.executablePath,
                tone: .warning,
                actionTitle: occupant.canAutomaticallyTerminate
                    ? "释放并重连"
                    : "强制释放…",
                actionEnabled: true,
                showsProgress: false
            )
        case .failed(let message):
            return BridgeDashboardPresentation(
                headline: "连接失败",
                detail: message,
                path: nil,
                tone: .negative,
                actionTitle: "重试",
                actionEnabled: true,
                showsProgress: false
            )
        case .stopped:
            return BridgeDashboardPresentation(
                headline: "未连接",
                detail: "本地翻译桥接已停止",
                path: nil,
                tone: .negative,
                actionTitle: "连接",
                actionEnabled: true,
                showsProgress: false
            )
        }
    }

    private func occupantSummary(_ occupant: BridgePortOccupant) -> String {
        var parts = [
            occupant.endpoint,
            "PID \(occupant.processIdentifier)",
            occupant.displayName,
        ]
        if let version = occupant.serviceVersion {
            parts.append("版本 \(version)")
        }
        return parts.joined(separator: " · ")
    }
}

struct BridgeDashboardPresentation: Equatable {
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
    let showsProgress: Bool
}
