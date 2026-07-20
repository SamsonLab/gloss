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

    public func start(
        runtime: BabelDOCRuntimeLaunch,
        timeout: Duration = .seconds(90)
    ) async throws -> URL {
        if let process, process.isRunning, let serviceBaseURL {
            return serviceBaseURL
        }
        await stop()

        guard
            let interpreter = BabelDOCExternalEngine.pythonInterpreter(
                for: runtime.executable
            )
        else {
            throw BabelDOCServiceError.pythonUnavailable
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Gloss-BabelDOC-Layout-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
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
            try? FileManager.default.removeItem(at: directory)
            throw BabelDOCServiceError.launchFailed(error.localizedDescription)
        }

        process = serviceProcess
        outputPipe = pipe
        workingDirectory = directory

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if Task.isCancelled {
                await stop()
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
                int(key): str(value)
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
