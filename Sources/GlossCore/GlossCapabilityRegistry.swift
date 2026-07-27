/// Reusable building blocks that can be shared by App and CLI product surfaces.
public enum GlossCapability: String, CaseIterable, Codable, Sendable {
    case textTranslation
    case documentTranslation
    case imageTextRecognition
    case translationLoopbackBridge
    case pdfLayoutAnalysis
    case pdfExport
    case providerConfiguration
    case languageConfiguration
    case appUpdates
    case diagnostics
    case launchAtLogin
    case browserBridge
    case chromeExtension
    case safariExtension
    case pdfRuntime
    case pdfBatchQueue
    case clipboardText
    case clipboardImage
    case screenshotCapture
    case selectionCapture
    case automaticSelection
    case appExclusions
    case glossaryManagement
    case translationHistory
}

/// User-facing workflows composed from one or more capabilities.
public enum GlossBusinessScenario: String, CaseIterable, Codable, Sendable {
    case browserTranslation
    case pdfTranslation
    case clipboardTranslation
    case imageTranslation
    case selectionTranslation
    case glossaryManagement
    case translationHistory

    public var requiredCapabilities: Set<GlossCapability> {
        switch self {
        case .browserTranslation:
            [
                .textTranslation,
                .translationLoopbackBridge,
                .providerConfiguration,
                .languageConfiguration,
                .browserBridge,
                .chromeExtension,
                .safariExtension,
            ]
        case .pdfTranslation:
            [
                .textTranslation,
                .documentTranslation,
                .translationLoopbackBridge,
                .pdfLayoutAnalysis,
                .pdfExport,
                .providerConfiguration,
                .languageConfiguration,
                .pdfRuntime,
                .pdfBatchQueue,
            ]
        case .clipboardTranslation:
            [
                .textTranslation,
                .providerConfiguration,
                .languageConfiguration,
                .clipboardText,
            ]
        case .imageTranslation:
            [
                .textTranslation,
                .imageTextRecognition,
                .providerConfiguration,
                .languageConfiguration,
                .clipboardImage,
                .screenshotCapture,
            ]
        case .selectionTranslation:
            [
                .textTranslation,
                .providerConfiguration,
                .languageConfiguration,
                .selectionCapture,
                .automaticSelection,
                .appExclusions,
            ]
        case .glossaryManagement:
            [.glossaryManagement]
        case .translationHistory:
            [.translationHistory]
        }
    }
}

/// Explicit CLI entry points. Both the parser and capability reporting use this
/// enum so product scenario names cannot drift from their command mappings.
public enum GlossCLICommand: String, CaseIterable, Codable, Sendable {
    case capabilities
    case text
    case browser
    case pdf

    public var businessScenario: GlossBusinessScenario? {
        switch self {
        case .capabilities:
            nil
        case .text:
            nil
        case .browser:
            .browserTranslation
        case .pdf:
            .pdfTranslation
        }
    }

    /// Capabilities exercised by the command itself. These can be narrower than
    /// the complete App scenario: `browser` translates already-extracted webpage
    /// text and therefore does not claim to drive Safari or Chrome.
    public var requiredCapabilities: Set<GlossCapability> {
        switch self {
        case .capabilities:
            []
        case .text, .browser:
            [
                .textTranslation,
                .providerConfiguration,
                .languageConfiguration,
            ]
        case .pdf:
            GlossBusinessScenario.pdfTranslation.requiredCapabilities
        }
    }
}

public struct GlossCLICommandMapping: Codable, Equatable, Sendable {
    public let command: GlossCLICommand
    public let scenario: GlossBusinessScenario?
    public let enabled: Bool
    public let requiredCapabilities: [GlossCapability]
    public let scenarioCapabilities: [GlossCapability]

    public init(
        command: GlossCLICommand,
        scenario: GlossBusinessScenario?,
        enabled: Bool,
        requiredCapabilities: [GlossCapability],
        scenarioCapabilities: [GlossCapability]
    ) {
        self.command = command
        self.scenario = scenario
        self.enabled = enabled
        self.requiredCapabilities = requiredCapabilities
        self.scenarioCapabilities = scenarioCapabilities
    }
}

public struct GlossCapabilityRegistry: Equatable, Sendable {
    private static let browserAdapterCapabilities: Set<GlossCapability> = [
        .chromeExtension,
        .safariExtension,
    ]

    /// The focused product surface. Secondary scenarios remain defined and can be
    /// restored by constructing a registry with a larger set.
    public static let defaultEnabledScenarios: Set<GlossBusinessScenario> = [
        .browserTranslation,
        .pdfTranslation,
    ]

    /// Operational controls are not business scenarios and remain available
    /// regardless of which translation surfaces are currently promoted.
    public static let infrastructureCapabilities: Set<GlossCapability> = [
        .providerConfiguration,
        .languageConfiguration,
        .appUpdates,
        .diagnostics,
        .launchAtLogin,
    ]

    /// Reusable execution and integration units that business scenarios compose.
    /// Configuration and operational controls remain regular capabilities, but
    /// are intentionally excluded from the core execution list.
    public static let coreExecutionCapabilities: Set<GlossCapability> = [
        .textTranslation,
        .documentTranslation,
        .imageTextRecognition,
        .translationLoopbackBridge,
        .browserBridge,
        .chromeExtension,
        .safariExtension,
        .pdfLayoutAnalysis,
        .pdfRuntime,
        .pdfBatchQueue,
        .pdfExport,
    ]

    public static let current = GlossCapabilityRegistry(
        distributionProfile: .current
    )

    private let configuredScenarios: Set<GlossBusinessScenario>
    public let unavailableCapabilities: Set<GlossCapability>

    public init(
        enabledScenarios: Set<GlossBusinessScenario> = Self.defaultEnabledScenarios,
        distributionProfile: GlossDistributionProfile = .current
    ) {
        configuredScenarios = enabledScenarios
        unavailableCapabilities =
            distributionProfile.safariExtensionAvailable
            ? []
            : [.safariExtension]
    }

    public var enabledScenarios: Set<GlossBusinessScenario> {
        configuredScenarios.filter(isAvailable)
    }

    public var availableCoreCapabilities: Set<GlossCapability> {
        Self.coreExecutionCapabilities.subtracting(unavailableCapabilities)
    }

    public var enabledCapabilities: Set<GlossCapability> {
        enabledScenarios.reduce(
            into: Self.infrastructureCapabilities.subtracting(
                unavailableCapabilities
            )
        ) {
            $0.formUnion(availableCapabilities(for: $1))
        }
    }

    public var enabledCoreCapabilities: Set<GlossCapability> {
        enabledCapabilities.intersection(Self.coreExecutionCapabilities)
    }

    public var commandMappings: [GlossCLICommandMapping] {
        GlossCLICommand.allCases.map { command in
            let scenario = command.businessScenario
            let requiredCapabilities = command.requiredCapabilities.sorted {
                $0.rawValue < $1.rawValue
            }
            let scenarioCapabilities =
                scenario.map(availableCapabilities(for:))?.sorted {
                    $0.rawValue < $1.rawValue
                } ?? []
            return GlossCLICommandMapping(
                command: command,
                scenario: scenario,
                enabled: (scenario.map(isEnabled) ?? true)
                    && requiredCapabilities.allSatisfy(supports),
                requiredCapabilities: requiredCapabilities,
                scenarioCapabilities: scenarioCapabilities
            )
        }
    }

    public func isEnabled(_ command: GlossCLICommand) -> Bool {
        commandMappings.first { $0.command == command }?.enabled == true
    }

    public func isEnabled(_ scenario: GlossBusinessScenario) -> Bool {
        configuredScenarios.contains(scenario) && isAvailable(scenario)
    }

    public func isAvailable(_ scenario: GlossBusinessScenario) -> Bool {
        let required = scenario.requiredCapabilities
        let unavailableRequired = required.intersection(
            unavailableCapabilities
        )
        guard scenario == .browserTranslation else {
            return unavailableRequired.isEmpty
        }

        let unavailableBase = unavailableRequired.subtracting(
            Self.browserAdapterCapabilities
        )
        let availableAdapters = Self.browserAdapterCapabilities
            .intersection(required)
            .subtracting(unavailableCapabilities)
        return unavailableBase.isEmpty && !availableAdapters.isEmpty
    }

    public func availableCapabilities(
        for scenario: GlossBusinessScenario
    ) -> Set<GlossCapability> {
        guard isAvailable(scenario) else { return [] }
        return scenario.requiredCapabilities.subtracting(
            unavailableCapabilities
        )
    }

    public func supports(_ capability: GlossCapability) -> Bool {
        enabledCapabilities.contains(capability)
    }
}
