import Darwin
import Foundation

public enum BabelDOCServiceError: LocalizedError, Equatable, Sendable {
    case pythonUnavailable
    case launchFailed(String)
    case startupTimedOut(String)

    public var errorDescription: String? {
        switch self {
        case .pythonUnavailable:
            "BabelDOC 的 Python 运行环境不可用。"
        case .launchFailed(let reason):
            "无法启动 PDF 版面服务：\(reason)"
        case .startupTimedOut(let log):
            "PDF 版面服务启动超时。\(log.isEmpty ? "" : "\n\(log)")"
        }
    }
}

/// Keeps BabelDOC's expensive DocLayout model resident while the PDF tool is open.
/// Individual BabelDOC translations remain isolated child processes and reuse this
/// loopback-only inference service through `--rpc-doclayout`.
public actor BabelDOCServiceSession {
    static let readyPrefix = "__GLOSS_BABELDOC_LAYOUT_READY__"
    static let workingDirectoryPrefix = "Gloss-BabelDOC-Layout-"
    static let ownerPIDFileName = ".owner-pid"
    static let legacyCleanupGraceInterval: TimeInterval = 24 * 60 * 60
    private static let layoutCacheDirectoryName = "layout-ir-cache"

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ value: Data) {
            lock.lock()
            data.append(value)
            lock.unlock()
        }

        func string() -> String {
            lock.lock()
            let snapshot = data
            lock.unlock()
            return String(decoding: snapshot, as: UTF8.self)
        }
    }

    private var process: Process?
    private var outputPipe: Pipe?
    private var workingDirectory: URL?
    private var serviceBaseURL: URL?

    public init() {}

    deinit {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        if let workingDirectory {
            try? FileManager.default.removeItem(at: workingDirectory)
        }
    }

    public var isRunning: Bool {
        process?.isRunning == true && serviceBaseURL != nil
    }

    public var layoutCacheDirectoryURL: URL? {
        guard isRunning, let workingDirectory else { return nil }
        return workingDirectory.appendingPathComponent(
            Self.layoutCacheDirectoryName,
            isDirectory: true
        )
    }

    public func start(
        runtime: BabelDOCRuntimeLaunch,
        timeout: Duration = .seconds(90)
    ) async throws -> URL {
        if let process, process.isRunning, let serviceBaseURL {
            return serviceBaseURL
        }
        await stop()
        Self.cleanupStaleWorkingDirectories()

        guard
            let interpreter = BabelDOCExternalEngine.pythonInterpreter(
                for: runtime.executable
            )
        else {
            throw BabelDOCServiceError.pythonUnavailable
        }

        let temporaryRoot = FileManager.default.temporaryDirectory
        let directory =
            temporaryRoot.appendingPathComponent(
                "\(Self.workingDirectoryPrefix)\(UUID().uuidString)",
                isDirectory: true
            )
        var shouldRemoveDirectory = true
        defer {
            if shouldRemoveDirectory {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let ownerPIDURL = directory.appendingPathComponent(Self.ownerPIDFileName)
        try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(
            to: ownerPIDURL,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: ownerPIDURL.path
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(
                Self.layoutCacheDirectoryName,
                isDirectory: true
            ),
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let scriptURL = directory.appendingPathComponent("layout_service.py")
        try Data(Self.layoutServiceScript.utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: scriptURL.path
        )

        let serviceProcess = Process()
        let pipe = Pipe()
        let output = OutputBuffer()
        serviceProcess.executableURL = URL(fileURLWithPath: interpreter)
        serviceProcess.arguments = [
            scriptURL.path,
            "--host", "127.0.0.1",
            "--port", "0",
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        serviceProcess.environment = environment
        serviceProcess.standardOutput = pipe
        serviceProcess.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            output.append(data)
        }

        do {
            try serviceProcess.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw BabelDOCServiceError.launchFailed(error.localizedDescription)
        }

        process = serviceProcess
        outputPipe = pipe
        workingDirectory = directory
        shouldRemoveDirectory = false

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        do {
            while clock.now < deadline {
                if Task.isCancelled {
                    throw CancellationError()
                }
                if let port = Self.readyPort(in: output.string()) {
                    let baseURL = URL(string: "http://127.0.0.1:\(port)")!
                    serviceBaseURL = baseURL
                    return baseURL
                }
                if !serviceProcess.isRunning {
                    let message = Self.tail(of: output.string())
                    await stop()
                    throw BabelDOCServiceError.launchFailed(
                        message.isEmpty ? "进程已退出" : message
                    )
                }
                try await Task.sleep(for: .milliseconds(150))
            }
        } catch is CancellationError {
            await stop()
            throw CancellationError()
        }

        let message = Self.tail(of: output.string())
        await stop()
        throw BabelDOCServiceError.startupTimedOut(message)
    }

    public func stop() async {
        serviceBaseURL = nil
        let runningProcess = process
        let pipe = outputPipe
        let directory = workingDirectory
        process = nil
        outputPipe = nil
        workingDirectory = nil

        pipe?.fileHandleForReading.readabilityHandler = nil
        if let runningProcess, runningProcess.isRunning {
            runningProcess.terminate()
            await Task.detached(priority: .utility) {
                runningProcess.waitUntilExit()
            }.value
        }
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func readyPort(in output: String) -> Int? {
        guard let range = output.range(of: readyPrefix) else { return nil }
        let suffix = output[range.upperBound...]
        let digits = suffix.prefix(while: { $0.isNumber })
        guard let port = Int(digits), (1...65_535).contains(port) else {
            return nil
        }
        return port
    }

    public static func cleanupStaleWorkingDirectories() {
        cleanupStaleWorkingDirectories(in: FileManager.default.temporaryDirectory)
    }

    static func cleanupStaleWorkingDirectories(
        in root: URL,
        now: Date = Date(),
        legacyGraceInterval: TimeInterval = legacyCleanupGraceInterval
    ) {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]
        guard
            let candidates = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        else { return }

        for candidate in candidates {
            let name = candidate.lastPathComponent
            guard name.hasPrefix(workingDirectoryPrefix) else { continue }
            let suffix = String(name.dropFirst(workingDirectoryPrefix.count))
            var fileInfo = stat()
            guard UUID(uuidString: suffix) != nil,
                lstat(candidate.path, &fileInfo) == 0,
                fileInfo.st_mode & S_IFMT == S_IFDIR,
                fileInfo.st_uid == getuid(),
                fileInfo.st_mode & 0o077 == 0,
                let values = try? candidate.resourceValues(forKeys: keys),
                values.isDirectory == true,
                values.isSymbolicLink != true
            else { continue }

            let ownerPIDURL = candidate.appendingPathComponent(ownerPIDFileName)
            var ownerPIDInfo = stat()
            if lstat(ownerPIDURL.path, &ownerPIDInfo) == 0,
                ownerPIDInfo.st_mode & S_IFMT == S_IFREG,
                ownerPIDInfo.st_uid == getuid(),
                ownerPIDInfo.st_mode & 0o077 == 0,
                (1...32).contains(ownerPIDInfo.st_size),
                let value = try? String(contentsOf: ownerPIDURL, encoding: .utf8),
                let ownerPID = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)),
                ownerPID > 0
            {
                guard !processExists(ownerPID) else { continue }
            } else {
                guard let modificationDate = values.contentModificationDate,
                    now.timeIntervalSince(modificationDate) >= legacyGraceInterval
                else { continue }
            }
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    private static func processExists(_ processIdentifier: Int32) -> Bool {
        if kill(pid_t(processIdentifier), 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private static func tail(of output: String) -> String {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(12)
            .joined(separator: "\n")
    }

    static let layoutServiceScript = #"""
        import argparse
        import json
        import os
        import threading
        import time
        from http import HTTPStatus
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        import cv2
        import msgpack
        import numpy as np
        from babeldoc.docvision.doclayout import OnnxModel

        READY_PREFIX = "__GLOSS_BABELDOC_LAYOUT_READY__"
        MODEL = OnnxModel.from_pretrained()
        MODEL_LOCK = threading.Lock()

        def monitor_parent(expected_parent_pid):
            while True:
                if os.getppid() != expected_parent_pid:
                    os._exit(0)
                time.sleep(1)

        def result_payload(result):
            names = {
                str(key): str(value)
                for key, value in dict(result.names).items()
            }
            boxes = []
            for box in result.boxes:
                boxes.append({
                    "xyxy": [float(value) for value in box.xyxy],
                    "conf": float(box.conf),
                    "cls": int(box.cls),
                })
            return {"boxes": boxes, "names": names}

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path != "/healthz":
                    self.send_error(HTTPStatus.NOT_FOUND)
                    return
                body = json.dumps({"status": "ok"}).encode("utf-8")
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                if self.path != "/inference":
                    self.send_error(HTTPStatus.NOT_FOUND)
                    return
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    request = msgpack.unpackb(self.rfile.read(length), raw=False)
                    images = []
                    for encoded in request.get("image", []):
                        image = cv2.imdecode(
                            np.frombuffer(encoded, dtype=np.uint8),
                            cv2.IMREAD_COLOR,
                        )
                        if image is None:
                            raise ValueError("invalid image")
                        images.append(image)
                    if not images:
                        raise ValueError("image is required")
                    with MODEL_LOCK:
                        results = MODEL.predict(
                            images,
                            imgsz=int(request.get("imgsz", 1024)),
                        )
                    body = msgpack.packb(
                        [result_payload(result) for result in results],
                        use_bin_type=True,
                    )
                    self.send_response(HTTPStatus.OK)
                    self.send_header("Content-Type", "application/msgpack")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except Exception as error:
                    body = json.dumps({"error": str(error)}).encode("utf-8")
                    self.send_response(HTTPStatus.BAD_REQUEST)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

            def log_message(self, _format, *_args):
                return

        def main():
            parser = argparse.ArgumentParser()
            parser.add_argument("--host", default="127.0.0.1")
            parser.add_argument("--port", type=int, default=0)
            parser.add_argument("--parent-pid", type=int, required=True)
            args = parser.parse_args()
            threading.Thread(
                target=monitor_parent,
                args=(args.parent_pid,),
                daemon=True,
            ).start()
            server = ThreadingHTTPServer((args.host, args.port), Handler)
            print(f"{READY_PREFIX}{server.server_address[1]}", flush=True)
            server.serve_forever()

        if __name__ == "__main__":
            main()
        """#
}
