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
        if try await isBackendHealthy() {
            return
        }

        while isEnsuringBackend {
            try await Task.sleep(nanoseconds: 250_000_000)
            if try await isBackendHealthy() {
                return
            }
        }

        isEnsuringBackend = true
        defer {
            isEnsuringBackend = false
        }

        if try await isBackendHealthy() {
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

    private func isBackendHealthy() async throws -> Bool {
        var request = URLRequest(url: configuration.healthURL)
        request.timeoutInterval = 1.2

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            guard (200..<300).contains(httpResponse.statusCode) else { return false }
            try Self.validateCapabilities(data)
            return true
        } catch let error as TranslatorAppError {
            throw error
        } catch {
            return false
        }
    }

    /// Reject older services that would silently ignore provider or App-only reasoning overrides.
    static func validateCapabilities(_ data: Data) throws {
        let health = try? JSONDecoder().decode(BackendHealth.self, from: data)
        guard health?.capabilities?.contains("model-switching") == true else {
            throw TranslatorAppError.backendError("当前本地服务不支持模型切换，请退出旧版 App 及其服务后重新启动。")
        }
        guard health?.capabilities?.contains("reasoning-selection") == true else {
            throw TranslatorAppError.backendError("当前本地服务不支持推理强度切换，请退出 App 后重新启动。")
        }
        guard health?.capabilities?.contains("generation-metrics") == true else {
            throw TranslatorAppError.backendError("当前本地服务不支持生成耗时，请退出 App 后重新启动。")
        }
        guard health?.capabilities?.contains("translation-streaming") == true else {
            throw TranslatorAppError.backendError("当前本地服务不支持流式翻译，请退出 App 后重新启动。")
        }
        _ = try health?.requestTimeout(modelCalls: 1)
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
            if try await isBackendHealthy() {
                return
            }

            if let ownedProcess, !ownedProcess.isRunning {
                self.ownedProcess = nil
                throw TranslatorAppError.backendStartupFailed(
                    "本地翻译服务提前退出，请检查 Python 依赖，或查看 /tmp/selected-text-translator-backend.log。"
                )
            }

            try await Task.sleep(nanoseconds: 500_000_000)
        }

        throw TranslatorAppError.backendStartupFailed(
            "本地翻译服务未在 15 秒内就绪：\(configuration.healthURL.absoluteString)"
        )
    }
}
