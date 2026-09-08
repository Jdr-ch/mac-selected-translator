import Foundation

@MainActor
final class BackendSupervisor {
    private let configuration: AppConfiguration
    private var ownedProcess: Process?
    private var backendLogHandle: FileHandle?
    private var isEnsuringBackend = false

    init(configuration: AppConfiguration) {
        self.configuration = configuration
    }

    /// Ensures the local LangChain backend is ready before a translation request.
    ///
    /// The menu-bar app can now be launched as a normal `.app`, so there may be
    /// no terminal session that started `scripts/run_backend.sh` first. This
    /// method keeps that startup responsibility inside the app while still
    /// reusing the existing Python backend and configuration loading behavior.
    func ensureBackendRunning() async throws {
        if await isBackendHealthy() {
            return
        }

        while isEnsuringBackend {
            try await Task.sleep(nanoseconds: 250_000_000)
            if await isBackendHealthy() {
                return
            }
        }

        isEnsuringBackend = true
        defer {
            isEnsuringBackend = false
        }

        if await isBackendHealthy() {
            return
        }

        try startBackendProcessIfNeeded()
        try await waitUntilHealthy()
    }

    func terminateOwnedBackend() {
        guard let ownedProcess, ownedProcess.isRunning else {
            return
        }
        ownedProcess.terminate()
        self.ownedProcess = nil
        try? backendLogHandle?.close()
        backendLogHandle = nil
    }

    private func isBackendHealthy() async -> Bool {
        var request = URLRequest(url: configuration.healthURL)
        request.timeoutInterval = 1.2

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return (200..<300).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    private func startBackendProcessIfNeeded() throws {
        if let ownedProcess, ownedProcess.isRunning {
            return
        }

        guard let projectRoot = configuration.projectRoot else {
            throw TranslatorAppError.backendProjectRootMissing
        }

        let runBackendScript = projectRoot
            .appendingPathComponent("scripts")
            .appendingPathComponent("run_backend.sh")
        guard FileManager.default.isExecutableFile(atPath: runBackendScript.path) else {
            throw TranslatorAppError.backendStartupFailed("找不到可执行后端脚本：\(runBackendScript.path)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bash", runBackendScript.path]
        process.currentDirectoryURL = projectRoot

        var environment = ProcessInfo.processInfo.environment
        environment["TRANSLATOR_PROJECT_ROOT"] = projectRoot.path
        // Finder-launched worktree builds must start Python on the same endpoint encoded in the app.
        environment["TRANSLATOR_BACKEND_HOST"] = configuration.backendBaseURL.host
        environment["TRANSLATOR_BACKEND_PORT"] = String(configuration.backendBaseURL.port ?? 8765)
        process.environment = environment

        let logHandle = try openBackendLogHandle()
        process.standardError = logHandle
        process.standardOutput = logHandle

        do {
            try process.run()
            ownedProcess = process
            backendLogHandle = logHandle
        } catch {
            try? logHandle.close()
            throw TranslatorAppError.backendStartupFailed(error.localizedDescription)
        }
    }

    private func openBackendLogHandle() throws -> FileHandle {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("selected-text-translator-backend.log")

        // The backend can emit request logs over time. Sending those logs to a
        // file keeps the Finder-launched app quiet while preventing stdout or
        // stderr pipes from filling up and blocking the Python process.
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        return handle
    }

    private func waitUntilHealthy() async throws {
        for _ in 0..<30 {
            if await isBackendHealthy() {
                return
            }

            if let ownedProcess, !ownedProcess.isRunning {
                self.ownedProcess = nil
                throw TranslatorAppError.backendStartupFailed(
                    "本地翻译服务提前退出，请检查钥匙串、.env 或环境变量中的 DASHSCOPE_API_KEY，或查看 /tmp/selected-text-translator-backend.log。"
                )
            }

            try await Task.sleep(nanoseconds: 500_000_000)
        }

        throw TranslatorAppError.backendStartupFailed(
            "本地翻译服务未在 15 秒内就绪：\(configuration.healthURL.absoluteString)"
        )
    }
}
