// 作者：huangxiaofeng
// 创建日期：2026-11-25
// 闲鱼助手：菜单栏常驻，打开即在后台运行闲鱼自动回复系统的 4 个服务，退出即全部停止。

import Cocoa
import IOKit.pwr_mgt
import ServiceManagement
import UserNotifications

// MARK: - 基础定义

struct ServiceDef {
    let key: String
    let title: String
    let port: UInt16
}

let kServices: [ServiceDef] = [
    ServiceDef(key: "backend-web", title: "后台接口", port: 8089),
    ServiceDef(key: "websocket", title: "消息收发", port: 8090),
    ServiceDef(key: "scheduler", title: "定时任务", port: 8091),
    ServiceDef(key: "frontend", title: "管理网页", port: 9000),
]

let kSupportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/XianyuKeeper")
let kConfigFile = kSupportDir.appendingPathComponent("config.env")
let kSetupStatusFile = kSupportDir.appendingPathComponent("setup-status")
// 直接进后台；根路径是公开首页，无论登录与否都显示「登录」按钮
let kAdminURL = URL(string: "http://127.0.0.1:9000/dashboard")!

enum SvcState {
    case stopped, starting, running, backoff, gaveUp, blocked

    var label: String {
        switch self {
        case .stopped: return "已停止"
        case .starting: return "启动中"
        case .running: return "运行中"
        case .backoff: return "异常，稍后重启"
        case .gaveUp: return "反复崩溃，已停止重试"
        case .blocked: return "端口被其他程序占用"
        }
    }

    var color: NSColor {
        switch self {
        case .running: return .systemGreen
        case .starting, .backoff: return .systemOrange
        case .stopped: return .secondaryLabelColor
        case .gaveUp, .blocked: return .systemRed
        }
    }
}

final class ServiceProc {
    let def: ServiceDef
    var pid: pid_t = 0
    var state: SvcState = .stopped
    var wantRunning = false
    var crashTimes: [Date] = []
    var restartAt: Date?

    init(_ def: ServiceDef) { self.def = def }
}

struct Config {
    let repoDir: String
    let brewPrefix: String

    static func load() -> Config? {
        guard let text = try? String(contentsOf: kConfigFile, encoding: .utf8) else { return nil }
        var kv: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            kv[k] = v
        }
        guard let repo = kv["REPO_DIR"], let brew = kv["BREW_PREFIX"],
              FileManager.default.fileExists(atPath: repo + "/backend-web/.venv/bin/python") else { return nil }
        return Config(repoDir: repo, brewPrefix: brew)
    }
}

// MARK: - 进程与端口工具

func isPortOpen(_ port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
}

@discardableResult
func runCommand(_ exe: String, _ args: [String], env: [String: String]? = nil) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let env = env { p.environment = env }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// 端口上监听进程的 pid 列表
func listeningPids(port: UInt16) -> [pid_t] {
    let r = runCommand("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
    return r.output.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
}

/// 进程的工作目录
func cwdOf(_ pid: pid_t) -> String? {
    let r = runCommand("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])
    return r.output.split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
}

/// 以独立进程组启动，stdout/stderr 追加写入日志
func spawnProcess(exe: String, args: [String], cwd: String, env: [String: String], logPath: String) -> pid_t? {
    var fa: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fa)
    defer { posix_spawn_file_actions_destroy(&fa) }
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&fa, 1, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&fa, 1, 2)
    posix_spawn_file_actions_addchdir_np(&fa, cwd)

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawnattr_setpgroup(&attr, 0)

    let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
    let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
    }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, exe, &fa, &attr, argv, envp)
    return rc == 0 ? pid : nil
}

/// 结束整个进程组：先 SIGTERM，超时再 SIGKILL
func terminateGroup(_ pid: pid_t, timeout: TimeInterval = 6) {
    guard pid > 0 else { return }
    kill(-pid, SIGTERM)
    kill(pid, SIGTERM)
    let deadline = Date().addingTimeInterval(timeout)
    var status: Int32 = 0
    while Date() < deadline {
        let r = waitpid(pid, &status, WNOHANG)
        if r == pid || (r == -1 && errno == ECHILD) {
            kill(-pid, SIGKILL)  // 清理组内残留子进程
            return
        }
        usleep(100_000)
    }
    kill(-pid, SIGKILL)
    kill(pid, SIGKILL)
    waitpid(pid, &status, 0)
}

// MARK: - 服务管理

final class ServiceManager {
    let config: Config
    let procs: [ServiceProc] = kServices.map(ServiceProc.init)
    let queue = DispatchQueue(label: "xianyu.services")
    var onChange: (() -> Void)?
    var onGaveUp: ((ServiceDef) -> Void)?
    private var timer: DispatchSourceTimer?
    private(set) var dependencyError: String?

    init(config: Config) { self.config = config }

    var logDir: String { config.repoDir + "/logs" }
    func logPath(_ key: String) -> String { "\(logDir)/\(key).log" }

    private var childEnv: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(config.brewPrefix)/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PYTHONUNBUFFERED"] = "1"
        env["LANG"] = "zh_CN.UTF-8"
        return env
    }

    private func notify() { DispatchQueue.main.async { self.onChange?() } }

    // 启动全部（按依赖顺序）
    func startAll() {
        queue.async {
            try? FileManager.default.createDirectory(atPath: self.logDir, withIntermediateDirectories: true)
            self.removeLegacyLaunchAgents()
            self.ensureDependencies()
            for p in self.procs {
                p.wantRunning = true
                p.crashTimes = []
                p.restartAt = nil
            }
            self.startProc(self.procs[0])
            self.waitForPort(self.procs[0], timeout: 180)
            for p in self.procs.dropFirst() where p.wantRunning { self.startProc(p) }
            self.startTimer()
        }
    }

    func stopAll(sync: Bool = false) {
        // 先置标记，让正在进行的 waitForPort 尽快退出，避免排队等待
        for p in procs { p.wantRunning = false }
        let work = {
            for p in self.procs.reversed() {
                p.wantRunning = false
                p.restartAt = nil
                if p.pid > 0 { terminateGroup(p.pid) }
                p.pid = 0
                p.state = .stopped
            }
            self.notify()
        }
        if sync { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    func restartAll() {
        stopAll()
        startAll()
    }

    /// 迁移：移除之前手动配置的 launchd 服务，避免与本应用抢端口
    private func removeLegacyLaunchAgents() {
        let agents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        let uid = getuid()
        for d in kServices {
            let label = "local.xianyu.\(d.key)"
            let plist = agents.appendingPathComponent("\(label).plist")
            if FileManager.default.fileExists(atPath: plist.path) {
                runCommand("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
                try? FileManager.default.removeItem(at: plist)
            }
        }
    }

    /// 确保 MySQL / Redis 在运行
    private func ensureDependencies() {
        dependencyError = nil
        let brew = config.brewPrefix + "/bin/brew"
        let deps: [(String, UInt16)] = [("mysql@8.4", 3306), ("redis", 6379)]
        for (formula, port) in deps where !isPortOpen(port) {
            runCommand(brew, ["services", "start", formula], env: childEnv)
        }
        for (formula, port) in deps {
            var ok = isPortOpen(port)
            for _ in 0..<60 where !ok {
                Thread.sleep(forTimeInterval: 1)
                ok = isPortOpen(port)
            }
            if !ok { dependencyError = "\(formula) 未能启动" }
        }
        notify()
    }

    /// 端口被占用时：本程序残留的进程直接清理，其他程序则标记为冲突
    private func freePort(_ p: ServiceProc) -> Bool {
        let pids = listeningPids(port: p.def.port)
        if pids.isEmpty { return true }
        for pid in pids {
            guard let cwd = cwdOf(pid), cwd.hasPrefix(config.repoDir) else { return false }
            let pgid = getpgid(pid)
            if pgid > 1 { kill(-pgid, SIGTERM) }
            kill(pid, SIGTERM)
        }
        for _ in 0..<50 {
            if listeningPids(port: p.def.port).isEmpty { return true }
            usleep(100_000)
        }
        for pid in listeningPids(port: p.def.port) { kill(pid, SIGKILL) }
        usleep(500_000)
        return listeningPids(port: p.def.port).isEmpty
    }

    private func rotateLog(_ path: String) {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > 20 * 1024 * 1024 {
            try? fm.removeItem(atPath: path + ".1")
            try? fm.moveItem(atPath: path, toPath: path + ".1")
        }
    }

    private func startProc(_ p: ServiceProc) {
        guard p.wantRunning else { return }
        guard freePort(p) else {
            p.state = .blocked
            notify()
            return
        }
        let repo = config.repoDir
        let exe: String, args: [String], cwd: String
        if p.def.key == "frontend" {
            cwd = repo + "/frontend"
            exe = cwd + "/node_modules/.bin/vite"
            args = ["--host", "127.0.0.1", "--port", "\(p.def.port)", "--strictPort"]
        } else {
            cwd = repo + "/" + p.def.key
            exe = cwd + "/.venv/bin/python"
            args = ["main.py"]
        }
        let log = logPath(p.def.key)
        rotateLog(log)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let banner = "\n===== \(fmt.string(from: Date())) 闲鱼助手启动 \(p.def.key) =====\n"
        if let h = FileHandle(forWritingAtPath: log) {
            h.seekToEndOfFile(); h.write(banner.data(using: .utf8)!); h.closeFile()
        } else {
            FileManager.default.createFile(atPath: log, contents: banner.data(using: .utf8))
        }
        if let pid = spawnProcess(exe: exe, args: args, cwd: cwd, env: childEnv, logPath: log) {
            p.pid = pid
            p.state = .starting
        } else {
            p.pid = 0
            p.state = .backoff
            p.restartAt = Date().addingTimeInterval(10)
        }
        notify()
    }

    private func waitForPort(_ p: ServiceProc, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, p.pid > 0, p.wantRunning {
            var status: Int32 = 0
            if waitpid(p.pid, &status, WNOHANG) == p.pid {
                handleExit(p)
                return
            }
            if isPortOpen(p.def.port) {
                p.state = .running
                notify()
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func handleExit(_ p: ServiceProc) {
        kill(-p.pid, SIGKILL)
        p.pid = 0
        guard p.wantRunning else {
            p.state = .stopped
            return
        }
        let now = Date()
        p.crashTimes = p.crashTimes.filter { now.timeIntervalSince($0) < 300 } + [now]
        if p.crashTimes.count > 5 {
            p.state = .gaveUp
            p.restartAt = nil
            let def = p.def
            DispatchQueue.main.async { self.onGaveUp?(def) }
        } else {
            p.state = .backoff
            p.restartAt = now.addingTimeInterval(10)
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        for p in procs {
            if p.pid > 0 {
                var status: Int32 = 0
                if waitpid(p.pid, &status, WNOHANG) == p.pid {
                    handleExit(p)
                } else {
                    p.state = isPortOpen(p.def.port) ? .running : .starting
                }
            } else if p.wantRunning, let at = p.restartAt, Date() >= at {
                p.restartAt = nil
                startProc(p)
            }
        }
        notify()
    }

    /// 手动重试某个已放弃 / 冲突的服务
    func retry(_ key: String) {
        queue.async {
            guard let p = self.procs.first(where: { $0.def.key == key }) else { return }
            p.wantRunning = true
            p.crashTimes = []
            if p.pid > 0 { terminateGroup(p.pid); p.pid = 0 }
            self.startProc(p)
        }
    }
}

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var manager: ServiceManager?
    var setupPollTimer: Timer?
    var busyText: String?

    // MARK: 防止休眠

    private let kPreventSleepKey = "preventSleep"
    private var sleepAssertion: IOPMAssertionID = 0

    /// 默认开启：闲鱼助手运行期间阻止系统闲置睡眠（屏幕仍可熄灭、锁屏）
    private var preventSleep: Bool {
        get { UserDefaults.standard.object(forKey: kPreventSleepKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: kPreventSleepKey) }
    }

    private func applySleepPolicy() {
        if preventSleep, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "XianyuKeeper: keep auto-reply and auto-delivery online" as CFString,
                &sleepAssertion)
        } else if !preventSleep, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    @objc func togglePreventSleep() {
        preventSleep.toggle()
        applySleepPolicy()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        applySleepPolicy()
        updateIcon()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        if let cfg = Config.load() {
            startManager(cfg)
        } else {
            firstRun()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion) }
        manager?.stopAll(sync: true)
        return .terminateNow
    }

    // MARK: 首次安装 / 更新

    private func firstRun() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "欢迎使用闲鱼助手"
        alert.informativeText = "首次使用需要安装运行环境（MySQL、Redis、Python、Node、浏览器和程序代码），大约需要 10–30 分钟，取决于网速。\n\n点击「开始安装」会打开一个终端窗口显示进度，安装完成后服务会自动启动。"
        alert.addButton(withTitle: "开始安装")
        alert.addButton(withTitle: "退出")
        if alert.runModal() == .alertFirstButtonReturn {
            runSetup(mode: "install")
        } else {
            NSApp.terminate(nil)
        }
    }

    private func runSetup(mode: String) {
        guard let script = Bundle.main.path(forResource: "setup", ofType: "sh") else { return }
        try? FileManager.default.createDirectory(at: kSupportDir, withIntermediateDirectories: true)
        try? "running".write(to: kSetupStatusFile, atomically: true, encoding: .utf8)
        let cmd = kSupportDir.appendingPathComponent("run-setup.command")
        let body = "#!/bin/bash\nexec /bin/bash '\(script)' \(mode)\n"
        try? body.write(to: cmd, atomically: true, encoding: .utf8)
        chmod(cmd.path, 0o755)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([cmd], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())

        busyText = mode == "update" ? "正在更新程序…" : "正在安装运行环境…"
        updateIcon()
        setupPollTimer?.invalidate()
        setupPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self = self else { return }
            let status = (try? String(contentsOf: kSetupStatusFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if status == "done" {
                t.invalidate()
                self.busyText = nil
                if let cfg = Config.load() {
                    if let m = self.manager, m.config.repoDir == cfg.repoDir {
                        m.startAll()
                    } else {
                        self.startManager(cfg)
                    }
                }
            } else if status == "failed" {
                t.invalidate()
                self.busyText = "环境安装未完成"
                self.updateIcon()
            }
        }
    }

    private func startManager(_ cfg: Config) {
        let m = ServiceManager(config: cfg)
        m.onChange = { [weak self] in self?.updateIcon() }
        m.onGaveUp = { [weak self] def in self?.sendNotice("\(def.title)反复崩溃", "已停止自动重启，请在闲鱼助手菜单里查看日志。") }
        manager = m
        m.startAll()
        updateIcon()
    }

    // MARK: 菜单栏图标与菜单

    private var overallColor: NSColor {
        guard busyText == nil else { return .systemOrange }
        guard let m = manager else { return .systemRed }
        if m.dependencyError != nil { return .systemRed }
        let states = m.procs.map(\.state)
        if states.allSatisfy({ $0 == .running }) { return .systemGreen }
        if states.contains(where: { $0 == .gaveUp || $0 == .blocked }) { return .systemRed }
        if states.allSatisfy({ $0 == .stopped }) { return .secondaryLabelColor }
        return .systemOrange
    }

    /// 菜单栏小鱼（模板图，自动适配深浅色菜单栏）
    private lazy var statusImage: NSImage = {
        let img = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            FishShape.draw(in: ctx, rect: rect.insetBy(dx: 1, dy: 0), color: NSColor.black.cgColor)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "闲鱼助手"
        return img
    }()

    func updateIcon() {
        guard let button = statusItem?.button else { return }
        button.image = statusImage
        button.imagePosition = .imageLeft
        button.attributedTitle = NSAttributedString(string: " ●", attributes: [
            .foregroundColor: overallColor,
            .font: NSFont.systemFont(ofSize: 9),
            .baselineOffset: 1,
        ])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header: String
        if let busy = busyText {
            header = busy
        } else if let m = manager {
            let n = m.procs.filter { $0.state == .running }.count
            header = m.dependencyError.map { "⚠️ \($0)" } ?? "闲鱼助手 · 运行中 \(n)/\(m.procs.count)"
        } else {
            header = "闲鱼助手 · 未安装"
        }
        menu.addItem(disabled(header, bold: true))

        if let m = manager {
            menu.addItem(.separator())
            for p in m.procs {
                let text = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: p.state.color])
                text.append(NSAttributedString(string: "\(p.def.title)  \(p.state.label)", attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                ]))
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.attributedTitle = text
                if p.state == .gaveUp || p.state == .blocked {
                    item.action = #selector(retryService(_:))
                    item.target = self
                    item.representedObject = p.def.key
                    item.toolTip = "点击重试"
                }
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(action("打开管理后台", #selector(openAdmin), key: "o"))
            menu.addItem(action("重启全部服务", #selector(restartAll), key: "r"))

            let logs = NSMenu()
            for d in kServices {
                let it = action("\(d.title)（\(d.key).log）", #selector(openLog(_:)))
                it.representedObject = d.key
                logs.addItem(it)
            }
            logs.addItem(.separator())
            logs.addItem(action("打开日志文件夹", #selector(openLogDir)))
            let logsItem = NSMenuItem(title: "查看日志", action: nil, keyEquivalent: "")
            logsItem.submenu = logs
            menu.addItem(logsItem)

            menu.addItem(.separator())
            menu.addItem(action("导出数据…", #selector(exportData)))
            menu.addItem(action("导入数据…", #selector(importData)))
            menu.addItem(action("更新程序代码…", #selector(updateCode)))
        }
        menu.addItem(action("重新运行环境安装…", #selector(repairSetup)))

        menu.addItem(.separator())
        let noSleep = action("防止电脑休眠（可熄屏、锁屏，合盖仍会休眠）", #selector(togglePreventSleep))
        noSleep.state = preventSleep ? .on : .off
        menu.addItem(noSleep)
        let login = action("登录时自动打开", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(action("关于闲鱼助手", #selector(showAbout)))
        menu.addItem(action("退出闲鱼助手（停止所有服务）", #selector(quit), key: "q"))
    }

    private func disabled(_ title: String, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if bold { item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]) }
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: 菜单动作

    @objc func openAdmin() { NSWorkspace.shared.open(kAdminURL) }

    @objc func restartAll() { manager?.restartAll() }

    @objc func retryService(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { manager?.retry(key) }
    }

    @objc func openLog(_ sender: NSMenuItem) {
        guard let m = manager, let key = sender.representedObject as? String else { return }
        let url = URL(fileURLWithPath: m.logPath(key))
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open([url], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func openLogDir() {
        guard let m = manager else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: m.logDir))
    }

    @objc func exportData() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmm"
        panel.nameFieldStringValue = "闲鱼助手数据-\(fmt.string(from: Date())).tar.gz"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runDataScript(["export", url.path], restart: false, done: "导出完成") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc func importData() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择从闲鱼助手导出的数据文件（.tar.gz）"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "导入会覆盖这台电脑上的现有数据"
        alert.informativeText = "包括闲鱼账号、卡券、商品配置和订单记录。导入期间服务会暂停。\n\n注意：同一个闲鱼账号不要在两台电脑上同时运行，否则会重复发货、互相挤掉登录。"
        alert.addButton(withTitle: "导入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        manager?.stopAll(sync: true)
        runDataScript(["import", url.path], restart: true, done: "导入完成，服务已重新启动", then: nil)
    }

    private func runDataScript(_ args: [String], restart: Bool, done: String, then: (() -> Void)?) {
        guard let script = Bundle.main.path(forResource: "data", ofType: "sh") else { return }
        busyText = args[0] == "export" ? "正在导出数据…" : "正在导入数据…"
        updateIcon()
        DispatchQueue.global().async {
            let r = runCommand("/bin/bash", [script] + args)
            DispatchQueue.main.async {
                self.busyText = nil
                if restart { self.manager?.startAll() }
                self.updateIcon()
                let alert = NSAlert()
                if r.status == 0 {
                    alert.messageText = done
                    alert.informativeText = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    alert.alertStyle = .critical
                    alert.messageText = "操作失败"
                    alert.informativeText = String(r.output.suffix(1500))
                }
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
                if r.status == 0 { then?() }
            }
        }
    }

    @objc func updateCode() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "更新程序代码"
        alert.informativeText = "会暂停服务，从你的 GitHub 仓库（vxiaofengs/xianyu-auto-reply）拉取最新代码并更新依赖，完成后自动重启服务。建议先「导出数据」备份。"
        alert.addButton(withTitle: "开始更新")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        manager?.stopAll(sync: true)
        runSetup(mode: "update")
    }

    @objc func repairSetup() {
        manager?.stopAll(sync: true)
        runSetup(mode: "install")
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "设置失败"
            alert.informativeText = "\(error.localizedDescription)\n\n请先把闲鱼助手拖到「应用程序」文件夹再设置。"
            alert.runModal()
        }
    }

    @objc func showAbout() {
        let credits = NSAttributedString(
            string: "在后台守护闲鱼自动回复与自动发货服务。\n管理后台：\(kAdminURL.absoluteString)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc func quit() { NSApp.terminate(nil) }

    private func sendNotice(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
