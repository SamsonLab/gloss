#!/usr/bin/env swift
import CoreGraphics
import Foundation

private enum ExportMode: String {
    case sideBySide = "side-by-side"
    case translationOnly = "translation-only"

    var filenameSuffix: String {
        switch self {
        case .sideBySide:
            "gloss-side-by-side"
        case .translationOnly:
            "gloss-translation-only"
        }
    }
}

private struct ScriptError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private struct Arguments {
    let mode: ExportMode
    let inputURL: URL
    let outputURL: URL
    let force: Bool

    init(commandLine: [String]) throws {
        guard commandLine.count >= 3,
            let mode = ExportMode(rawValue: commandLine[1])
        else {
            throw ScriptError(message: Self.usage)
        }

        var force = false
        var positional: [String] = []
        for argument in commandLine.dropFirst(2) {
            if argument == "--force" || argument == "-f" {
                force = true
            } else if argument.hasPrefix("-") {
                throw ScriptError(
                    message: "Unknown option: \(argument)\n\n\(Self.usage)"
                )
            } else {
                positional.append(argument)
            }
        }

        guard positional.count == 1 || positional.count == 2 else {
            throw ScriptError(message: Self.usage)
        }

        let inputURL = Self.fileURL(positional[0])
        let outputURL =
            positional.count == 2
            ? Self.fileURL(positional[1])
            : Self.defaultOutputURL(for: inputURL, mode: mode)

        guard inputURL.pathExtension.lowercased() == "pdf" else {
            throw ScriptError(message: "Input must be a PDF: \(inputURL.path)")
        }
        guard outputURL.pathExtension.lowercased() == "pdf" else {
            throw ScriptError(message: "Output must be a PDF: \(outputURL.path)")
        }
        guard inputURL != outputURL else {
            throw ScriptError(message: "Input and output paths must be different.")
        }

        self.mode = mode
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.force = force
    }

    private static func fileURL(_ path: String) -> URL {
        URL(
            fileURLWithPath: (path as NSString).expandingTildeInPath
        ).standardizedFileURL
    }

    private static func defaultOutputURL(
        for inputURL: URL,
        mode: ExportMode
    ) -> URL {
        let rawStem = inputURL.deletingPathExtension().lastPathComponent
        let dualSuffix = "-gloss-dual"
        let stem =
            rawStem.hasSuffix(dualSuffix)
            ? String(rawStem.dropLast(dualSuffix.count))
            : rawStem
        return inputURL.deletingLastPathComponent().appendingPathComponent(
            "\(stem)-\(mode.filenameSuffix).pdf"
        )
    }

    private static let usage = """
        Usage: pdf_dual_export.swift MODE INPUT.pdf [OUTPUT.pdf] [--force]

          MODE    side-by-side | translation-only

        The input must be a Gloss bilingual PDF whose pages alternate between
        source and translation. Existing outputs are preserved unless --force
        is supplied.
        """
}

private func validateInput(_ arguments: Arguments) throws -> CGPDFDocument {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: arguments.inputURL.path),
        let document = CGPDFDocument(arguments.inputURL as CFURL)
    else {
        throw ScriptError(
            message: "Cannot read input PDF: \(arguments.inputURL.path)"
        )
    }
    guard document.numberOfPages > 0 else {
        throw ScriptError(message: "Input PDF has no pages.")
    }
    guard document.numberOfPages.isMultiple(of: 2) else {
        throw ScriptError(
            message:
                "Expected alternating source/translation pairs, but the input has \(document.numberOfPages) pages."
        )
    }
    if fileManager.fileExists(atPath: arguments.outputURL.path),
        !arguments.force
    {
        throw ScriptError(
            message:
                "Output already exists: \(arguments.outputURL.path)\nUse --force to replace it."
        )
    }
    try fileManager.createDirectory(
        at: arguments.outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    return document
}

private func temporaryOutputURL(for outputURL: URL) -> URL {
    outputURL.deletingLastPathComponent().appendingPathComponent(
        ".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp"
    )
}

private func installTemporaryOutput(
    _ temporaryURL: URL,
    at outputURL: URL,
    force: Bool
) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: outputURL.path) {
        guard force else {
            throw ScriptError(message: "Output already exists: \(outputURL.path)")
        }
        _ = try fileManager.replaceItemAt(outputURL, withItemAt: temporaryURL)
    } else {
        try fileManager.moveItem(at: temporaryURL, to: outputURL)
    }
}

private func exportTranslationOnly(
    from source: CGPDFDocument,
    arguments: Arguments
) throws {
    let temporaryURL = temporaryOutputURL(for: arguments.outputURL)
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    let context = try makePDFContext(
        at: temporaryURL,
        source: source,
        mode: arguments.mode
    )

    for sourcePageNumber in stride(
        from: 2,
        through: source.numberOfPages,
        by: 2
    ) {
        guard let page = source.page(at: sourcePageNumber) else {
            throw ScriptError(
                message: "Cannot read translated page \(sourcePageNumber)."
            )
        }
        let pageSize = displayedSize(of: page)
        let mediaBox = CGRect(origin: .zero, size: pageSize)
        context.beginPDFPage(pageInfo(mediaBox: mediaBox))
        draw(page: page, in: mediaBox, context: context)
        context.endPDFPage()
    }
    context.closePDF()

    try installTemporaryOutput(
        temporaryURL,
        at: arguments.outputURL,
        force: arguments.force
    )
}

private func displayedSize(of page: CGPDFPage) -> CGSize {
    let bounds = page.getBoxRect(.mediaBox)
    let rotation = ((page.rotationAngle % 360) + 360) % 360
    if rotation == 90 || rotation == 270 {
        return CGSize(width: bounds.height, height: bounds.width)
    }
    return bounds.size
}

private func draw(
    page: CGPDFPage,
    in targetRect: CGRect,
    context: CGContext
) {
    context.saveGState()
    context.concatenate(
        page.getDrawingTransform(
            .mediaBox,
            rect: targetRect,
            rotate: 0,
            preserveAspectRatio: true
        )
    )
    context.drawPDFPage(page)
    context.restoreGState()
}

private func pdfString(
    named key: String,
    in dictionary: CGPDFDictionaryRef?
) -> String? {
    guard let dictionary else { return nil }
    var value: CGPDFStringRef?
    guard CGPDFDictionaryGetString(dictionary, key, &value),
        let value
    else {
        return nil
    }
    return CGPDFStringCopyTextString(value) as String?
}

private func documentInfo(
    from source: CGPDFDocument,
    mode: ExportMode
) -> CFDictionary {
    var info: [CFString: Any] = [
        kCGPDFContextCreator: "Gloss PDF exporter",
        kCGPDFContextSubject:
            mode == .sideBySide
            ? "Source and translation side by side"
            : "Translation-only derivative of a Gloss bilingual PDF",
    ]
    if let title = pdfString(named: "Title", in: source.info) {
        info[kCGPDFContextTitle] = title
    }
    if let author = pdfString(named: "Author", in: source.info) {
        info[kCGPDFContextAuthor] = author
    }
    return info as CFDictionary
}

private func makePDFContext(
    at temporaryURL: URL,
    source: CGPDFDocument,
    mode: ExportMode
) throws -> CGContext {
    guard let consumer = CGDataConsumer(url: temporaryURL as CFURL) else {
        throw ScriptError(
            message: "Cannot create output PDF: \(temporaryURL.path)"
        )
    }
    var firstPageBox = CGRect(x: 0, y: 0, width: 1, height: 1)
    guard
        let context = CGContext(
            consumer: consumer,
            mediaBox: &firstPageBox,
            documentInfo(from: source, mode: mode)
        )
    else {
        throw ScriptError(
            message: "Cannot initialize PDF writer: \(temporaryURL.path)"
        )
    }
    return context
}

private func pageInfo(mediaBox: CGRect) -> CFDictionary {
    var mediaBox = mediaBox
    let mediaBoxData =
        Data(
            bytes: &mediaBox,
            count: MemoryLayout<CGRect>.size
        ) as CFData
    return [kCGPDFContextMediaBox: mediaBoxData] as CFDictionary
}

private func exportSideBySide(
    from source: CGPDFDocument,
    arguments: Arguments
) throws {
    let temporaryURL = temporaryOutputURL(for: arguments.outputURL)
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    let context = try makePDFContext(
        at: temporaryURL,
        source: source,
        mode: arguments.mode
    )

    for sourcePageNumber in stride(from: 1, through: source.numberOfPages, by: 2) {
        guard let leftPage = source.page(at: sourcePageNumber),
            let rightPage = source.page(at: sourcePageNumber + 1)
        else {
            throw ScriptError(
                message: "Cannot read page pair starting at \(sourcePageNumber)."
            )
        }

        let leftSize = displayedSize(of: leftPage)
        let rightSize = displayedSize(of: rightPage)
        let canvasSize = CGSize(
            width: leftSize.width + rightSize.width,
            height: max(leftSize.height, rightSize.height)
        )
        let mediaBox = CGRect(origin: .zero, size: canvasSize)
        context.beginPDFPage(pageInfo(mediaBox: mediaBox))
        draw(
            page: leftPage,
            in: CGRect(
                x: 0,
                y: canvasSize.height - leftSize.height,
                width: leftSize.width,
                height: leftSize.height
            ),
            context: context
        )
        draw(
            page: rightPage,
            in: CGRect(
                x: leftSize.width,
                y: canvasSize.height - rightSize.height,
                width: rightSize.width,
                height: rightSize.height
            ),
            context: context
        )
        context.endPDFPage()
    }
    context.closePDF()

    try installTemporaryOutput(
        temporaryURL,
        at: arguments.outputURL,
        force: arguments.force
    )
}

do {
    let arguments = try Arguments(commandLine: CommandLine.arguments)
    let source = try validateInput(arguments)
    switch arguments.mode {
    case .sideBySide:
        try exportSideBySide(from: source, arguments: arguments)
    case .translationOnly:
        try exportTranslationOnly(from: source, arguments: arguments)
    }
    print(arguments.outputURL.path)
} catch {
    let message =
        (error as? LocalizedError)?.errorDescription
        ?? String(describing: error)
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}
