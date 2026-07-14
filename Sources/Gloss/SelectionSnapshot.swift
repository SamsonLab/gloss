import AppKit
@preconcurrency import ApplicationServices
import GlossCore

@MainActor
struct SelectionSnapshot {
    let id = UUID()
    let text: String
    let surroundingContext: String?
    let contentKind: TranslationContentKind
    let applicationName: String
    let bundleIdentifier: String?
    let processIdentifier: pid_t?
    let element: AXUIElement?
    let isEditable: Bool
    let anchor: NSPoint

    var canReplace: Bool {
        isEditable || processIdentifier != nil
    }

    init(
        text: String,
        surroundingContext: String?,
        contentKind: TranslationContentKind = .selection,
        applicationName: String,
        bundleIdentifier: String?,
        processIdentifier: pid_t?,
        element: AXUIElement?,
        isEditable: Bool,
        anchor: NSPoint
    ) {
        self.text = text
        self.surroundingContext = surroundingContext
        self.contentKind = contentKind
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.element = element
        self.isEditable = isEditable
        self.anchor = anchor
    }
}
