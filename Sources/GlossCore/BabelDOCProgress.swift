import Foundation

public enum BabelDOCTranslationPhase: String, CaseIterable, Sendable {
    case launching
    case parsing
    case translating
    case typesetting
    case saving
    case finalizing
    case completed
}

public struct BabelDOCPhaseTimings: Equatable, Sendable {
    public let launchingMilliseconds: Int
    public let parsingMilliseconds: Int
    public let translatingMilliseconds: Int
    public let typesettingMilliseconds: Int
    public let savingMilliseconds: Int
    public let finalizingMilliseconds: Int

    public init(
        launchingMilliseconds: Int = 0,
        parsingMilliseconds: Int = 0,
        translatingMilliseconds: Int = 0,
        typesettingMilliseconds: Int = 0,
        savingMilliseconds: Int = 0,
        finalizingMilliseconds: Int = 0
    ) {
        self.launchingMilliseconds = launchingMilliseconds
        self.parsingMilliseconds = parsingMilliseconds
        self.translatingMilliseconds = translatingMilliseconds
        self.typesettingMilliseconds = typesettingMilliseconds
        self.savingMilliseconds = savingMilliseconds
        self.finalizingMilliseconds = finalizingMilliseconds
    }
}

public struct BabelDOCProgressUpdate: Equatable, Sendable {
    public let phase: BabelDOCTranslationPhase
    public let stageName: String?
    public let overallProgress: Double
    public let stageCurrent: Int?
    public let stageTotal: Int?
    public let partIndex: Int?
    public let totalParts: Int?
    public let elapsedMilliseconds: Int
    public let timings: BabelDOCPhaseTimings

    public init(
        phase: BabelDOCTranslationPhase,
        stageName: String? = nil,
        overallProgress: Double,
        stageCurrent: Int? = nil,
        stageTotal: Int? = nil,
        partIndex: Int? = nil,
        totalParts: Int? = nil,
        elapsedMilliseconds: Int,
        timings: BabelDOCPhaseTimings
    ) {
        self.phase = phase
        self.stageName = stageName
        self.overallProgress = min(100, max(0, overallProgress))
        self.stageCurrent = stageCurrent
        self.stageTotal = stageTotal
        self.partIndex = partIndex
        self.totalParts = totalParts
        self.elapsedMilliseconds = max(0, elapsedMilliseconds)
        self.timings = timings
    }
}

extension BabelDOCExternalEngine {
    static let progressLinePrefix = "__GLOSS_BABELDOC_PROGRESS__"

    struct ProgressWireEvent: Decodable, Equatable, Sendable {
        let type: String
        let stage: String?
        let stageCurrent: Int?
        let stageTotal: Int?
        let overallProgress: Double?
        let partIndex: Int?
        let totalParts: Int?

        enum CodingKeys: String, CodingKey {
            case type
            case stage
            case stageCurrent = "stage_current"
            case stageTotal = "stage_total"
            case overallProgress = "overall_progress"
            case partIndex = "part_index"
            case totalParts = "total_parts"
        }
    }

    final class ProgressOutputParser: @unchecked Sendable {
        private let lock = NSLock()
        private var bufferedData = Data()

        func append(_ data: Data) -> [ProgressWireEvent] {
            lock.lock()
            defer { lock.unlock() }
            bufferedData.append(data)

            var events: [ProgressWireEvent] = []
            while let newline = bufferedData.firstIndex(of: 0x0A) {
                let lineData = bufferedData[..<newline]
                bufferedData.removeSubrange(...newline)
                if let event = Self.parseLine(Data(lineData)) {
                    events.append(event)
                }
            }
            return events
        }

        func finish() -> [ProgressWireEvent] {
            lock.lock()
            defer { lock.unlock() }
            guard !bufferedData.isEmpty else { return [] }
            let remainder = bufferedData
            bufferedData.removeAll(keepingCapacity: false)
            return Self.parseLine(remainder).map { [$0] } ?? []
        }

        private static func parseLine(_ data: Data) -> ProgressWireEvent? {
            let line = String(decoding: data, as: UTF8.self)
            guard let prefixRange = line.range(of: BabelDOCExternalEngine.progressLinePrefix)
            else { return nil }
            let payload = line[prefixRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let payloadData = payload.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ProgressWireEvent.self, from: payloadData)
        }
    }

    final class ProgressTimeline: @unchecked Sendable {
        private let lock = NSLock()
        private let startedAt: UInt64
        private var phaseStartedAt: UInt64
        private var currentPhase: BabelDOCTranslationPhase = .launching
        private var completedMilliseconds: [BabelDOCTranslationPhase: Int] = [:]
        private var latestOverallProgress = 0.0

        init(startedAt: UInt64 = DispatchTime.now().uptimeNanoseconds) {
            self.startedAt = startedAt
            self.phaseStartedAt = startedAt
        }

        func initialUpdate() -> BabelDOCProgressUpdate {
            lock.lock()
            defer { lock.unlock() }
            return makeUpdate(
                phase: .launching,
                stageName: nil,
                overallProgress: 0,
                stageCurrent: nil,
                stageTotal: nil,
                partIndex: nil,
                totalParts: nil,
                now: startedAt
            )
        }

        func update(_ event: ProgressWireEvent) -> BabelDOCProgressUpdate? {
            guard
                event.type == "progress_start"
                    || event.type == "progress_update"
                    || event.type == "progress_end"
            else { return nil }

            lock.lock()
            defer { lock.unlock() }
            let now = DispatchTime.now().uptimeNanoseconds
            let phase = Self.phase(for: event.stage)
            transition(to: phase, at: now)
            latestOverallProgress = max(
                latestOverallProgress,
                event.overallProgress ?? latestOverallProgress
            )
            return makeUpdate(
                phase: phase,
                stageName: event.stage,
                overallProgress: latestOverallProgress,
                stageCurrent: event.stageCurrent,
                stageTotal: event.stageTotal,
                partIndex: event.partIndex,
                totalParts: event.totalParts,
                now: now
            )
        }

        func finish() -> BabelDOCProgressUpdate {
            lock.lock()
            defer { lock.unlock() }
            let now = DispatchTime.now().uptimeNanoseconds
            transition(to: .completed, at: now)
            latestOverallProgress = 100
            return makeUpdate(
                phase: .completed,
                stageName: nil,
                overallProgress: 100,
                stageCurrent: nil,
                stageTotal: nil,
                partIndex: nil,
                totalParts: nil,
                now: now
            )
        }

        private func transition(
            to phase: BabelDOCTranslationPhase,
            at now: UInt64
        ) {
            guard phase != currentPhase else { return }
            completedMilliseconds[currentPhase, default: 0] +=
                Self.milliseconds(from: phaseStartedAt, to: now)
            currentPhase = phase
            phaseStartedAt = now
        }

        private func makeUpdate(
            phase: BabelDOCTranslationPhase,
            stageName: String?,
            overallProgress: Double,
            stageCurrent: Int?,
            stageTotal: Int?,
            partIndex: Int?,
            totalParts: Int?,
            now: UInt64
        ) -> BabelDOCProgressUpdate {
            BabelDOCProgressUpdate(
                phase: phase,
                stageName: stageName,
                overallProgress: overallProgress,
                stageCurrent: stageCurrent,
                stageTotal: stageTotal,
                partIndex: partIndex,
                totalParts: totalParts,
                elapsedMilliseconds: Self.milliseconds(from: startedAt, to: now),
                timings: timings(at: now)
            )
        }

        private func timings(at now: UInt64) -> BabelDOCPhaseTimings {
            func duration(_ phase: BabelDOCTranslationPhase) -> Int {
                completedMilliseconds[phase, default: 0]
                    + (currentPhase == phase
                        ? Self.milliseconds(from: phaseStartedAt, to: now)
                        : 0)
            }
            return BabelDOCPhaseTimings(
                launchingMilliseconds: duration(.launching),
                parsingMilliseconds: duration(.parsing),
                translatingMilliseconds: duration(.translating),
                typesettingMilliseconds: duration(.typesetting),
                savingMilliseconds: duration(.saving),
                finalizingMilliseconds: duration(.finalizing)
            )
        }

        private static func phase(for stage: String?) -> BabelDOCTranslationPhase {
            let normalized = stage?.lowercased() ?? ""
            if normalized.contains("translate paragraph")
                || normalized.contains("term extraction")
            {
                return .translating
            }
            if normalized.contains("typesetting")
                || normalized.contains("add fonts")
                || normalized.contains("drawing instructions")
            {
                return .typesetting
            }
            if normalized.contains("subset font")
                || normalized.contains("save pdf")
            {
                return .saving
            }
            return .parsing
        }

        private static func milliseconds(from start: UInt64, to end: UInt64) -> Int {
            Int((end - min(start, end)) / 1_000_000)
        }
    }
}
