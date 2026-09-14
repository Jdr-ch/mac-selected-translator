import AppKit

// 由跨进程桌面测试单独启动，只发布测试窗口编号；主测试退出时终止本进程。
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 160),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.title = "工作场景跨进程验证（自动关闭）"
window.isReleasedWhenClosed = false
window.orderFrontRegardless()
try String(window.windowNumber).write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
// 父测试异常结束时也不留下自建窗口。
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { app.terminate(nil) }
app.run()
