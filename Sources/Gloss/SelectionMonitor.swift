import AppKit
@preconcurrency import ApplicationServices
import GlossCore

private func glossEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<SelectionMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let location = event.location
    let flags = event.flags
    let clickCount = event.getIntegerValueField(.mouseEventClickState)
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

    Task { @MainActor in
        monitor.handleEvent(
            type: type,
            location: location,
            flags: flags,
            clickCount: clickCount,
            keyCode: keyCode
        )
    }
    return Unmanaged.passUnretained(event)
}

@MainActor
final class SelectionMonitor {
    typealias SelectionHandler = @MainActor (SelectionSnapshot) -> Void
    typealias DismissHandler = @MainActor () -> Void
    typealias AutomaticCapturePolicy = @MainActor (String?) -> Bool

    private static let maximumSelectionLength = 50_000
    private static let contextRadius = 500
    private static let longPressDelay: Duration = .milliseconds(450)
    private static let ignoredBundleIdentifiers: Set<String> = [
        "com.1password.1password",
        "com.1password.1password7",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
    ]
    private static let keyboardSelectionKeyCodes: Set<Int64> = [
        0, 115, 116, 119, 121, 123, 124, 125, 126,
    ]
    private static let escapeKeyCode: Int64 = 53

    private let onSelection: SelectionHandler
    private let onDismiss: DismissHandler
    private let shouldIgnorePoint: @MainActor (NSPoint) -> Bool
    private let shouldCaptureAutomatically: AutomaticCapturePolicy
    private var globalShortcut: GlobalShortcut
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mouseDownLocation: CGPoint?
    private var ignoreMouseSequence = false
    private var probeTask: Task<Void, Never>?
    private var longPressTask: Task<Void, Never>?

    init(
        onSelection: @escaping SelectionHandler,
        onDismiss: @escaping DismissHandler,
        shouldIgnorePoint: @escaping @MainActor (NSPoint) -> Bool,
        shouldCaptureAutomatically: @escaping AutomaticCapturePolicy,
        globalShortcut: GlobalShortcut
    ) {
        self.onSelection = onSelection
        self.onDismiss = onDismiss
        self.shouldIgnorePoint = shouldIgnorePoint
        self.shouldCaptureAutomatically = shouldCaptureAutomatically
        self.globalShortcut = globalShortcut
    }

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let options =
            [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let eventTypes: [CGEventType] = [
            .leftMouseDown,
            .leftMouseDragged,
            .leftMouseUp,
            .keyDown,
            .keyUp,
            .scrollWheel,
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << CGEventMask(type.rawValue))
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: glossEventTapCallback,
                userInfo: userInfo
            )
        else {
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        probeTask?.cancel()
        probeTask = nil
        cancelLongPress()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    func captureNow() {
        scheduleSelectionProbe(delays: [0], automatic: false)
    }

    func updateGlobalShortcut(_ shortcut: GlobalShortcut) {
        globalShortcut = shortcut
    }

    func handleEvent(
        type: CGEventType,
        location: CGPoint,
        flags: CGEventFlags,
        clickCount: Int64,
        keyCode: Int64
    ) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        let appKitPoint = NSEvent.mouseLocation
        switch type {
        case .leftMouseDown:
            probeTask?.cancel()
            probeTask = nil
            cancelLongPress()
            ignoreMouseSequence = shouldIgnorePoint(appKitPoint)
            mouseDownLocation = location
            if !ignoreMouseSequence {
                onDismiss()
                scheduleLongPress(from: location)
            }

        case .leftMouseDragged:
            guard let mouseDownLocation else { return }
            if hypot(location.x - mouseDownLocation.x, location.y - mouseDownLocation.y) >= 3 {
                cancelLongPress()
            }

        case .leftMouseUp:
            cancelLongPress()
            defer {
                mouseDownLocation = nil
                ignoreMouseSequence = false
            }
            guard !ignoreMouseSequence,
                !flags.contains(.maskCommand),
                let mouseDownLocation
            else { return }

            let distance = hypot(location.x - mouseDownLocation.x, location.y - mouseDownLocation.y)
            let selectedByPointer = distance >= 3 || clickCount >= 2 || flags.contains(.maskShift)
            if selectedByPointer {
                scheduleSelectionProbe(delays: [45_000_000, 130_000_000], automatic: true)
            }

        case .keyDown:
            probeTask?.cancel()
            probeTask = nil
            cancelLongPress()
            if keyCode == Self.escapeKeyCode {
                onDismiss()
                return
            }
            if globalShortcut.matches(keyCode: keyCode, modifiers: flags.rawValue) {
                onDismiss()
                scheduleSelectionProbe(delays: [0, 80_000_000], automatic: false)
            }

        case .keyUp:
            let selectsWithKeyboard =
                Self.keyboardSelectionKeyCodes.contains(keyCode)
                && (flags.contains(.maskShift) || (keyCode == 0 && flags.contains(.maskCommand)))
            if selectsWithKeyboard {
                onDismiss()
                scheduleSelectionProbe(delays: [30_000_000, 110_000_000], automatic: true)
            }

        case .scrollWheel:
            probeTask?.cancel()
            probeTask = nil
            cancelLongPress()
            if !shouldIgnorePoint(appKitPoint) {
                onDismiss()
            }

        default:
            break
        }
    }

    private func scheduleLongPress(from origin: CGPoint) {
        longPressTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.longPressDelay)
            guard !Task.isCancelled,
                let self,
                !ignoreMouseSequence,
                let mouseDownLocation,
                hypot(mouseDownLocation.x - origin.x, mouseDownLocation.y - origin.y) < 3
            else { return }
            scheduleSelectionProbe(delays: [0, 80_000_000], automatic: true)
        }
    }

    private func cancelLongPress() {
        longPressTask?.cancel()
        longPressTask = nil
    }

    private func scheduleSelectionProbe(delays: [UInt64], automatic: Bool) {
        probeTask?.cancel()
        probeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for delay in delays {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard !Task.isCancelled else { return }
                if let selection = await captureSelection(automatic: automatic) {
                    guard !Task.isCancelled else { return }
                    onSelection(selection)
                    return
                }
            }
        }
    }

    private func captureSelection(automatic: Bool) async -> SelectionSnapshot? {
        guard Self.isAccessibilityTrusted,
            let application = NSWorkspace.shared.frontmostApplication,
            application.bundleIdentifier != Bundle.main.bundleIdentifier,
            !Self.ignoredBundleIdentifiers.contains(application.bundleIdentifier ?? ""),
            !automatic || shouldCaptureAutomatically(application.bundleIdentifier)
        else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        let element = copyElementAttribute(kAXFocusedUIElementAttribute as CFString, from: systemWide)
        guard element.map({ !isSecure($0) }) ?? true else { return nil }

        var selectedText = element.flatMap {
            copyStringAttribute(kAXSelectedTextAttribute as CFString, from: $0)
        }
        if selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            selectedText = nil
        }
        if selectedText == nil {
            selectedText = await SelectionClipboard.readSelectedText()
        }
        guard let selectedText,
            !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            selectedText.count <= Self.maximumSelectionLength
        else { return nil }

        var settable = DarwinBoolean(false)
        if let element {
            AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        }

        return SelectionSnapshot(
            text: selectedText,
            surroundingContext: element.flatMap(surroundingContext),
            applicationName: application.localizedName ?? "当前应用",
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processIdentifier,
            element: element,
            isEditable: settable.boolValue,
            anchor: element.flatMap(selectionAnchor) ?? NSEvent.mouseLocation
        )
    }

    private func selectionAnchor(for element: AXUIElement) -> NSPoint? {
        guard var range = copySelectedRange(from: element),
            let rangeValue = AXValueCreate(.cfRange, &range)
        else { return nil }

        var rawBounds: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeValue,
                &rawBounds
            ) == .success,
            let rawBounds,
            CFGetTypeID(rawBounds) == AXValueGetTypeID()
        else { return nil }

        let boundsValue = unsafeDowncast(rawBounds, to: AXValue.self)
        var bounds = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &bounds),
            !bounds.isNull,
            !bounds.isInfinite,
            let primaryScreen = NSScreen.screens.first
        else { return nil }

        return NSPoint(
            x: bounds.midX,
            y: primaryScreen.frame.maxY - bounds.minY
        )
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        let role = copyStringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
        let subrole = copyStringAttribute(kAXSubroleAttribute as CFString, from: element) ?? ""
        return role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    private func surroundingContext(for element: AXUIElement) -> String? {
        guard let fullText = copyStringAttribute(kAXValueAttribute as CFString, from: element),
            fullText.count <= 100_000,
            let range = copySelectedRange(from: element),
            range.location >= 0,
            range.length >= 0
        else { return nil }

        let text = fullText as NSString
        guard range.location <= text.length,
            range.location + range.length <= text.length
        else { return nil }

        let start = max(0, range.location - Self.contextRadius)
        let end = min(text.length, range.location + range.length + Self.contextRadius)
        let context = text.substring(with: NSRange(location: start, length: end - start))
        return context == fullText ? nil : context
    }

    private func copySelectedRange(from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                &value
            ) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }

        let axValue = unsafeDowncast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private func copyElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }
}
