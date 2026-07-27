import GlossCore

/// Maps enabled business scenarios to App lifecycle work and external entry points.
///
/// Keep this policy separate from `GlossAppDelegate` so a scenario being hidden in
/// the UI also prevents its background services and file handlers from starting.
struct GlossAppScenarioActivation: Equatable {
    let configuresSystemServices: Bool
    let observesWorkspaceApplications: Bool
    let startsTranslationBridge: Bool
    let preparesBrowserExtensions: Bool
    let preparesPDFRuntime: Bool
    let prewarmsTranslationProvider: Bool
    let acceptsPDFOpenRequests: Bool

    init(registry: GlossCapabilityRegistry) {
        configuresSystemServices =
            registry.supports(.clipboardText)
            || registry.supports(.clipboardImage)
        observesWorkspaceApplications = registry.supports(.selectionCapture)
        startsTranslationBridge = registry.supports(.translationLoopbackBridge)
        preparesBrowserExtensions = registry.isEnabled(.browserTranslation)
        preparesPDFRuntime = registry.supports(.pdfRuntime)
        prewarmsTranslationProvider = registry.supports(.textTranslation)
        acceptsPDFOpenRequests = registry.isEnabled(.pdfTranslation)
    }
}
