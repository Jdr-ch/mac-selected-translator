import AppKit
import Foundation
import Testing
@testable import SelectedTextTranslatorApp

/// Native feature checks use isolated preferences and do not launch the installed menu-bar app.
@Suite(.serialized)
struct FlowchartTests {
    @Test @MainActor
    func startsBlankAndOnlyMigratesTheUntouchedExample() throws {
        let name = "FlowchartTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let create = { FlowchartSession(defaults: defaults) { _, _, _ in throw FlowchartError.message("not called") } }
        let blank = create()
        #expect(blank.state.input.isEmpty)
        #expect(blank.state.document == .empty)
        struct LegacySavedState: Codable {
            var input: String
            var document: FlowchartDocument
            var style: FlowchartStyle
            var model: String
            var recentModels: [String]
        }
        var legacy = LegacySavedState(
            input: "描述编译型语言的执行过程：语言文件-编译器-汇编代码-汇编器-二进制机器码-链接器-可执行exe文件",
            document: .example, style: .staircase, model: "diagram-model", recentModels: ["diagram-model"])
        defaults.set(try JSONEncoder().encode(legacy), forKey: "flowchart.document.v1")
        let migrated = create()
        #expect(migrated.state.input.isEmpty)
        #expect(migrated.state.document == .empty)
        #expect(migrated.provider == .qwen)
        #expect(migrated.state.style == .staircase)
        legacy.document.steps[0].description = "用户自己的说明"
        defaults.set(try JSONEncoder().encode(legacy), forKey: "flowchart.document.v1")
        let restored = create()
        #expect(restored.state.input == legacy.input)
        #expect(restored.state.document.steps[0].description == "用户自己的说明")
    }

    @Test
    func wireDocumentPreservesTextAndRejectsUnsupportedContent() throws {
        let document = FlowchartDocument.example
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(FlowchartDocument.self, from: data)
        try decoded.validate()
        #expect(decoded.steps.map(\.title) == document.steps.map(\.title))
        #expect(decoded.steps.count == 7)
        #expect(!String(decoding: data, as: UTF8.self).contains(document.steps[0].id.uuidString))
        var invalid = decoded
        invalid.steps[0].iconID = "unknown"
        #expect(throws: FlowchartError.self) { try invalid.validate() }
    }

    @Test @MainActor
    func editingPersistsAndReordersWithoutCallingAI() throws {
        let name = "FlowchartTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var calls = 0
        let session = FlowchartSession(defaults: defaults) { _, _, _ in
            calls += 1
            return FlowchartResponse(diagram: .example, model: "test", aiMS: 1)
        }
        session.edit { $0.document = .example; $0.input = "我的编译流程" }
        let second = session.state.document.steps[1].id
        session.moveStep(id: second, offset: -1)
        session.edit { $0.style = .staircase; $0.document.title = "编辑后的标题" }
        session.selectProvider(.codex)
        #expect(session.state.document.steps[0].title == "编译器")
        #expect(calls == 0)
        let restored = FlowchartSession(defaults: defaults) { _, _, _ in throw FlowchartError.message("not called") }
        #expect(restored.state.style == .staircase)
        #expect(restored.provider == .qwen)
        #expect(restored.state.document.title == "编辑后的标题")
        #expect(restored.state.document.steps.map(\.title) == session.state.document.steps.map(\.title))
    }

    @Test @MainActor
    func generationCapturesProviderAndReasoningAndFailureKeepsDocument() async throws {
        let name = "FlowchartTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var suppliedProvider: ModelProvider?
        var suppliedReasoning: ModelReasoning?
        var shouldFail = false
        let globalSelection = ModelSelectionStore(defaults: defaults)
        globalSelection.select(.codex)
        globalSelection.selectReasoning(.high)
        globalSelection.select(.qwen)
        let session = FlowchartSession(defaults: defaults,
                                       defaultProvider: { globalSelection.provider },
                                       reasoningForProvider: { globalSelection.reasoning(for: $0) }) { _, provider, reasoning in
            suppliedProvider = provider
            suppliedReasoning = reasoning
            if shouldFail { throw FlowchartError.message("模型不可用") }
            return FlowchartResponse(diagram: .example, model: provider.rawValue, aiMS: 123)
        }
        session.edit { $0.input = "语言文件 → 编译器" }
        session.selectProvider(.codex)
        session.generate()
        session.selectProvider(.qwen)
        #expect(globalSelection.provider == .qwen)
        globalSelection.select(.codex)
        globalSelection.selectReasoning(.fastest)
        while session.isGenerating { await Task.yield() }
        #expect(suppliedProvider == .codex)
        #expect(suppliedReasoning == .high)
        #expect(session.provider == .qwen)
        #expect(session.lastAIMS == 123)
        #expect(session.status == "已生成·codex-高 0.1秒")
        let previous = session.state.document
        shouldFail = true
        session.generate()
        while session.isGenerating { await Task.yield() }
        #expect(suppliedProvider == .qwen)
        #expect(suppliedReasoning == .fastest)
        #expect(session.hasError)
        #expect(session.state.document == previous)
    }

    @Test @MainActor
    func cancelledGenerationCannotReplaceNewerEdits() async throws {
        let name = "FlowchartTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let session = FlowchartSession(defaults: defaults) { _, _, _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return FlowchartResponse(diagram: .example, model: "late", aiMS: 100)
        }
        session.edit { $0.input = "语言文件 → 编译器" }
        session.generate()
        await Task.yield()
        session.cancel()
        session.edit { $0.document.title = "取消后保留的编辑" }
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(!session.isGenerating)
        #expect(session.state.document.title == "取消后保留的编辑")
        #expect(session.lastAIMS == nil)
    }

    @Test @MainActor
    func webKitExportsBothCompleteTemplatesAndMeasuresWarmPerformance() async throws {
        _ = NSApplication.shared
        let preview = FlowchartPreview()
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                            styleMask: .borderless, backing: .buffered, defer: false)
        host.contentView = preview.webView
        let output = ProcessInfo.processInfo.environment["FLOWCHART_OUTPUT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for style in FlowchartStyle.allCases {
            try await preview.render(.example, style: style)
            var renders: [Double] = []
            var svgTimes: [Double] = []
            var pngTimes: [Double] = []
            var lastSVG = Data()
            var lastPNG = Data()
            for _ in 0..<20 {
                var start = CFAbsoluteTimeGetCurrent()
                try await preview.render(.example, style: style)
                renders.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                start = CFAbsoluteTimeGetCurrent()
                lastSVG = try await preview.svgData()
                svgTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                start = CFAbsoluteTimeGetCurrent()
                lastPNG = try await preview.pngData(longEdge: 2400)
                pngTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            let svg = try XMLDocument(data: lastSVG)
            #expect(try svg.nodes(forXPath: "//*[@data-step-index]").count == 7)
            let bitmap = try #require(NSBitmapImageRep(data: lastPNG))
            #expect(max(bitmap.pixelsWide, bitmap.pixelsHigh) == 2400)
            let statistics: [String: Any] = ["style": style.rawValue,
                "render_ms": Self.percentiles(renders), "svg_ms": Self.percentiles(svgTimes),
                "png_ms": Self.percentiles(pngTimes)]
            let json = try JSONSerialization.data(withJSONObject: statistics, options: [.sortedKeys])
            print("FLOWCHART_BENCHMARK " + String(decoding: json, as: UTF8.self))
            #expect(renders.sorted()[18] < 200)
            #expect(svgTimes.sorted()[18] < 100)
            #expect(pngTimes.sorted()[18] < 1000)
            if let output {
                try lastSVG.write(to: output.appendingPathComponent("flowchart-\(style.rawValue).svg"))
                try lastPNG.write(to: output.appendingPathComponent("flowchart-\(style.rawValue).png"))
                try json.write(to: output.appendingPathComponent("benchmark-\(style.rawValue).json"))
            }
        }
        _ = host
    }

    @Test @MainActor
    func variableNodeCountsAndLongTextFitBothTemplates() async throws {
        _ = NSApplication.shared
        let preview = FlowchartPreview()
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                            styleMask: .borderless, backing: .buffered, defer: false)
        host.contentView = preview.webView
        for count in [2, 7, 12] {
            var document = FlowchartDocument.example
            document.steps = (0..<count).map { index in
                var step = FlowchartDocument.example.steps[index % 7]
                step.id = UUID()
                if count == 12 {
                    step.title = "第\(index + 1)步：中文与VeryLongIdentifierWithoutAnySpaces混合的长标题"
                    step.description = "保留用户文字 <script> & \"quotes\"，说明会根据实际宽度换行，不能遮挡其他步骤。"
                }
                return step
            }
            for style in FlowchartStyle.allCases {
                try await preview.render(document, style: style)
                let result = try await preview.webView.callAsyncJavaScript("""
                    const svg = document.querySelector('#stage > svg');
                    const width = Number(svg.getAttribute('width'));
                    const height = Number(svg.getAttribute('height'));
                    const texts = [...svg.querySelectorAll('text')].filter(t => t.textContent.trim());
                    const boxes = texts.map(t => ({label:t.getAttribute('data-text-block'), b:t.getBBox()}));
                    const failures = boxes.filter(({b}) => b.x < -1 || b.y < -1 || b.x+b.width > width+1 || b.y+b.height > height+1).map(v => v.label);
                    for(let i=0;i<boxes.length;i++) for(let j=i+1;j<boxes.length;j++) {
                        const a=boxes[i].b, b=boxes[j].b;
                        if(Math.min(a.x+a.width,b.x+b.width)-Math.max(a.x,b.x)>1 && Math.min(a.y+a.height,b.y+b.height)-Math.max(a.y,b.y)>1) failures.push(boxes[i].label+' overlaps '+boxes[j].label);
                    }
                    const ids=[...svg.querySelectorAll('[id]')].map(e=>e.id);
                    if(new Set(ids).size!==ids.length) failures.push('duplicate SVG IDs');
                    if(svg.querySelector('script')) failures.push('unescaped text');
                    return failures;
                    """, arguments: [:], in: nil, contentWorld: .page)
                #expect((result as? [String]) == [])
            }
        }
        _ = host
    }

    @Test @MainActor
    func nativePanelKeepsControlsInBoundsAtSupportedSizes() async throws {
        _ = NSApplication.shared
        let name = "FlowchartTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let configuration = AppConfiguration(environment: ["TRANSLATOR_BACKEND_URL": "http://127.0.0.1:1"])
        var revealedURL: URL?
        let globalSelection = ModelSelectionStore(defaults: defaults)
        let controller = FlowchartWindowController(configuration: configuration, defaults: defaults,
                                                   defaultProvider: { globalSelection.provider },
                                                   revealExport: { revealedURL = $0 }) {}
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        try await controller.preview.render(controller.session.state.document, style: .horizontal)
        let empty = try await controller.preview.webView.callAsyncJavaScript(
            "return !document.querySelector('#stage > svg') && !document.getElementById('empty-state').hidden;",
            arguments: [:], in: nil, contentWorld: .page)
        #expect(empty as? Bool == true)
        controller.session.edit { $0.document = .example }
        let exported = FileManager.default.temporaryDirectory.appendingPathComponent("flowchart-\(UUID().uuidString).svg")
        defer { try? FileManager.default.removeItem(at: exported) }
        await controller.performExport(isPNG: false, destination: exported)
        #expect(FileManager.default.fileExists(atPath: exported.path))
        let reveal = try #require(Self.controls(in: content).compactMap { $0 as? NSButton }.first { $0.title == "在 Finder 中显示" })
        #expect(!reveal.isHidden)
        #expect(reveal.toolTip == exported.path)
        reveal.performClick(nil)
        #expect(revealedURL == exported)
        for size in [NSSize(width: 1100, height: 720), NSSize(width: 900, height: 620)] {
            window.setContentSize(size)
            content.layoutSubtreeIfNeeded()
            let buttons = Self.controls(in: content).compactMap { $0 as? NSButton }
            let generate = try #require(buttons.first { $0.title == "生成" })
            let cancel = try #require(buttons.first { $0.title == "取消" })
            let actions = try #require(generate.superview)
            #expect(abs(generate.frame.maxX - actions.bounds.maxX) <= 1)
            #expect(cancel.frame.maxX < generate.frame.minX)
            let labels = Self.controls(in: content).compactMap { $0 as? NSTextField }.map(\.stringValue)
            #expect(labels.contains("图表标题") && labels.contains("副标题") && labels.contains("步骤"))
            for control in Self.controls(in: content) where !control.isHidden {
                if let button = control as? NSButton { #expect(button.title != "Button" || button.imagePosition == .imageOnly) }
                let bounds = content.convert(control.bounds, from: control)
                #expect(bounds.width >= 0 && bounds.height >= 0)
                // Step rows can scroll outside their viewport; only fixed toolbar/editor controls are checked here.
                if control.enclosingScrollView == nil {
                    #expect(content.bounds.insetBy(dx: -1, dy: -1).contains(bounds))
                }
            }
        }
        let modelBox = try #require(Self.controls(in: content).compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles == ["Codex", "Qwen"] })
        let documentBeforeOpening = controller.session.state.document
        globalSelection.select(.codex)
        controller.showWindow()
        #expect(modelBox.titleOfSelectedItem == "Codex")
        modelBox.selectItem(withTitle: "Qwen")
        #expect(modelBox.sendAction(modelBox.action, to: modelBox.target))
        #expect(controller.session.provider == .qwen)
        #expect(globalSelection.provider == .codex)
        controller.showWindow()
        modelBox.menu?.update()
        #expect(modelBox.titleOfSelectedItem == "Qwen")
        window.close()
        controller.showWindow()
        #expect(modelBox.titleOfSelectedItem == "Codex")
        globalSelection.select(.qwen)
        #expect(controller.session.provider == .codex)
        window.close()
        controller.showWindow()
        #expect(modelBox.titleOfSelectedItem == "Qwen")
        #expect(controller.session.state.document == documentBeforeOpening)
        #expect(controller.window === window)
        #expect(window.isVisible)
        try await controller.preview.render(controller.session.state.document, style: .horizontal)
        if let directory = ProcessInfo.processInfo.environment["FLOWCHART_OUTPUT_DIR"] {
            // Native controls and WebKit live in different backing stores; compose their native snapshots.
            window.setContentSize(NSSize(width: 1100, height: 720))
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let webImage: NSImage = try await withCheckedThrowingContinuation { continuation in
                controller.preview.webView.takeSnapshot(with: nil) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? FlowchartError.message("原生预览截图失败。")) }
                }
            }
            let nativeImage = NSImage(size: content.bounds.size)
            nativeImage.lockFocus()
            bitmap.draw(in: content.bounds)
            webImage.draw(in: content.convert(controller.preview.webView.bounds, from: controller.preview.webView))
            nativeImage.unlockFocus()
            let tiff = try #require(nativeImage.tiffRepresentation)
            let composed = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try composed.write(to: URL(fileURLWithPath: directory).appendingPathComponent("flowchart-panel.png"))
            // Capture this test window only, after the compositor has presented its native controls.
            try await Task.sleep(nanoseconds: 200_000_000)
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber),
                URL(fileURLWithPath: directory).appendingPathComponent("flowchart-panel-screen.png").path]
            try capture.run()
            capture.waitUntilExit()
            print("FLOWCHART_NATIVE_CAPTURE status=\(capture.terminationStatus)")
        }
        window.close()
        controller.shutdown()
    }

    @Test(arguments: [true, false]) @MainActor
    func exportConfirmationClosesPanelOnlyWhenRevealingFile(showInFinder: Bool) async throws {
        _ = NSApplication.shared
        let name = "FlowchartTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let configuration = AppConfiguration(environment: ["TRANSLATOR_BACKEND_URL": "http://127.0.0.1:1"])
        var revealedURL: URL?
        let controller = FlowchartWindowController(configuration: configuration, defaults: defaults,
                                                   revealExport: { revealedURL = $0 }) {}
        let window = try #require(controller.window)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
            controller.shutdown()
        }
        let document = FlowchartDocument.example
        controller.session.edit { $0.document = document }
        controller.showWindow()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flowchart-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = directory.appendingPathComponent("导出提示验证.png")
        await controller.performExport(isPNG: true, destination: saved)
        // Verify the native confirmation after a real file write, including its exact Finder destination.
        for _ in 0..<150 {
            if let sheet = window.attachedSheet, !(sheet is NSSavePanel) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let confirmation = try #require(window.attachedSheet)
        #expect(!(confirmation is NSSavePanel))
        let controls = Self.controls(in: try #require(confirmation.contentView))
        let messages = controls.compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(messages.contains("导出成功"))
        #expect(messages.contains { $0.contains(directory.path) && $0.contains("导出提示验证.png") })
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: saved)))
        #expect(max(bitmap.pixelsWide, bitmap.pixelsHigh) == 2400)
        if let output = ProcessInfo.processInfo.environment["FLOWCHART_OUTPUT_DIR"] {
            try await Task.sleep(nanoseconds: 200_000_000)
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(confirmation.windowNumber),
                URL(fileURLWithPath: output).appendingPathComponent("flowchart-export-confirmation.png").path]
            try capture.run()
            capture.waitUntilExit()
            #expect(capture.terminationStatus == 0)
        }
        let actionTitle = showInFinder ? "在 Finder 中显示" : "完成"
        let action = try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == actionTitle })
        action.performClick(nil)
        for _ in 0..<100 {
            if window.attachedSheet == nil && window.isVisible == !showInFinder { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(window.attachedSheet == nil)
        #expect(window.isVisible == !showInFinder)
        #expect(revealedURL == (showInFinder ? saved : nil))
        // The retained editor must reopen intact; its footer uses the same Finder handoff behavior.
        controller.showWindow()
        #expect(controller.window === window)
        #expect(window.isVisible)
        #expect(controller.session.state.document == document)
        let content = try #require(window.contentView)
        let reveal = try #require(Self.controls(in: content).compactMap { $0 as? NSButton }.first { $0.title == "在 Finder 中显示" })
        reveal.performClick(nil)
        #expect(revealedURL == saved)
        #expect(!window.isVisible)
    }

    @Test @MainActor
    func commandCopyAndPasteReachEveryNativeInput() throws {
        _ = NSApplication.shared
        let name = "FlowchartTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let configuration = AppConfiguration(environment: ["TRANSLATOR_BACKEND_URL": "http://127.0.0.1:1"])
        let controller = FlowchartWindowController(configuration: configuration, defaults: defaults) {}
        controller.session.edit { $0.document = .example }
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        defer { window.close(); controller.shutdown() }
        // Native NSTextView commands use the general pasteboard; restore all original representations.
        let pasteboard = NSPasteboard.general
        let original = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { pasteboard.clearContents(); pasteboard.writeObjects(original) }
        let fields = Self.controls(in: content).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        #expect(fields.count == 17)
        for field in fields {
            field.selectText(nil)
            let editor = try #require(window.firstResponder as? NSTextView)
            try Self.checkCopyAndPaste(editor: editor, window: window)
        }
        let input = try #require(Self.views(in: content).compactMap { $0 as? NSTextView }.first { !$0.isFieldEditor })
        #expect(window.makeFirstResponder(input))
        try Self.checkCopyAndPaste(editor: input, window: window)
    }

    /// Exercise the window's actual key-equivalent path with native pasteboard text, not a mocked action.
    @MainActor private static func checkCopyAndPaste(editor: NSTextView, window: NSWindow) throws {
        let text = "流程图 Copy / Paste 中文"
        editor.selectAll(nil)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let paste = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "v",
            charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        #expect(window.performKeyEquivalent(with: paste))
        #expect(editor.string == text)
        editor.selectAll(nil)
        NSPasteboard.general.clearContents()
        let copy = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "c",
            charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        #expect(window.performKeyEquivalent(with: copy))
        #expect(NSPasteboard.general.string(forType: .string) == text)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FLOWCHART_RUNTIME_ROOT"] != nil))
    @MainActor
    func configuredWorktreePortStartsItsOwnBackend() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["FLOWCHART_RUNTIME_ROOT"])
        let configuration = AppConfiguration(environment: [
            "TRANSLATOR_PROJECT_ROOT": root, "TRANSLATOR_BACKEND_URL": "http://127.0.0.1:18765"
        ])
        let supervisor = BackendSupervisor(configuration: configuration)
        defer { supervisor.terminateOwnedBackend() }
        try await supervisor.ensureBackendRunning()
        let client = FlowchartClient(configuration: configuration)
        do {
            _ = try await client.generate(text: "", provider: .qwen, reasoning: .fastest)
            Issue.record("Empty input should not reach the model")
        } catch {
            #expect(error.localizedDescription == "请输入流程描述。")
        }
    }

    private static func percentiles(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return ["p50": median, "p95": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]]
    }

    @MainActor private static func controls(in view: NSView) -> [NSControl] {
        view.subviews.flatMap { child in (child as? NSControl).map { [$0] } ?? [] } + view.subviews.flatMap { controls(in: $0) }
    }

    @MainActor private static func views(in view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { views(in: $0) }
    }
}
