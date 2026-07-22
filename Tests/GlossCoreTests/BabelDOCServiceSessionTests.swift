import Foundation
import XCTest

@testable import GlossCore

final class BabelDOCServiceSessionTests: XCTestCase {
    func testCleansOnlySafeStaleDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        func makeDirectory(
            prefix: String = BabelDOCServiceSession.workingDirectoryPrefix,
            ownerPID: Int32? = nil,
            age: TimeInterval = 0,
            permissions: Int = 0o700
        ) throws -> URL {
            let url = root.appendingPathComponent(
                "\(prefix)\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: permissions]
            )
            if let ownerPID {
                let marker = url.appendingPathComponent(
                    BabelDOCServiceSession.ownerPIDFileName
                )
                try Data("\(ownerPID)\n".utf8).write(to: marker)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: marker.path
                )
            }
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-age)],
                ofItemAtPath: url.path
            )
            return url
        }

        let deadOwner = try makeDirectory(ownerPID: Int32.max)
        let liveOwner = try makeDirectory(
            ownerPID: Int32(ProcessInfo.processInfo.processIdentifier),
            age: 2 * 24 * 60 * 60
        )
        let oldLegacy = try makeDirectory(age: 2 * 24 * 60 * 60)
        let recentLegacy = try makeDirectory(age: 10 * 60)
        let unrelated = try makeDirectory(
            prefix: "Unrelated-",
            age: 2 * 24 * 60 * 60
        )
        let unsafePermissions = try makeDirectory(
            age: 2 * 24 * 60 * 60,
            permissions: 0o755
        )
        let symlinkTarget = try makeDirectory(prefix: "Target-")
        let symlink = root.appendingPathComponent(
            "\(BabelDOCServiceSession.workingDirectoryPrefix)\(UUID().uuidString)"
        )
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: symlinkTarget
        )

        BabelDOCServiceSession.cleanupStaleWorkingDirectories(
            in: root,
            now: now
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: deadOwner.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldLegacy.path))
        for preserved in [
            liveOwner,
            recentLegacy,
            unrelated,
            unsafePermissions,
            symlink,
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: preserved.path),
                preserved.lastPathComponent
            )
        }
    }
}
