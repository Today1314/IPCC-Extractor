import SwiftUI
import AppKit

struct Carrier: Identifiable {
    let id: String
    let name: String
    let label: String
    let source: String
    let issue: String
    var selected: Bool
    var isCommon: Bool { ["cmcc_cn", "unicom_cn", "chinatelecom_usim_cn", "cbn_cn"].contains(name.lowercased()) }
}

final class Model: ObservableObject {
    @Published var carriers: [Carrier] = []
    @Published var input = "尚未选择固件或文件夹"
    @Published var status = "选择本地 IPSW 固件开始扫描。"
    @Published var notice = ""
    @Published var busy = false
    @Published var query = ""
    @Published var ready = false
    @Published var closing = false
    @Published var language: String = UserDefaults.standard.string(forKey: "uiLanguage") ?? ((Locale.preferredLanguages.first ?? "zh").lowercased().hasPrefix("zh") ? "zh" : "en")
    var isEnglish: Bool { language == "en" }
    func tr(_ chinese: String, _ english: String) -> String { isEnglish ? english : chinese }
    func display(_ text: String) -> String { translateBackend(text, english: isEnglish) }
    func setLanguage(_ value: String) { language = value == "en" ? "en" : "zh"; UserDefaults.standard.set(language, forKey: "uiLanguage") }
    func carrierTitle(_ carrier: Carrier) -> String {
        if isEnglish {
            switch carrier.name.lowercased() {
            case "cmcc_cn": return "China Mobile"
            case "unicom_cn": return "China Unicom"
            case "chinatelecom_usim_cn": return "China Telecom"
            case "cbn_cn": return "China Broadnet"
            default: break
            }
        }
        return carrier.label.isEmpty ? tr("名称未提供", "Name unavailable") : carrier.label
    }
    var cleanupCompletion: ((Bool, String) -> Void)?
    private var process: Process?
    private var writer: FileHandle?
    private let queue = DispatchQueue(label: "ipcc.output")
    private var buffer = Data()

    init() { start() }
    private func start() {
        guard let script = Bundle.main.path(forResource: "engine", ofType: "py") else {
            status = "程序文件不完整，请重新解压。"; return
        }
        let runtime = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/3.13")
        let python = runtime.appendingPathComponent("bin/python3.13")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            status = "应用运行组件缺失，请重新安装完整应用。"; return
        }
        let p = Process(); p.executableURL = python
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("PYTHON") && !$0.key.hasPrefix("DYLD_") && $0.key != "VIRTUAL_ENV" }
        env["PYTHONHOME"] = runtime.path
        env["PYTHONNOUSERSITE"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"
        p.environment = env
        p.arguments = ["-s", "-u", script]
        let inputPipe = Pipe(), outputPipe = Pipe(), errorPipe = Pipe()
        p.standardInput = inputPipe; p.standardOutput = outputPipe; p.standardError = errorPipe
        let out = outputPipe.fileHandleForReading
        out.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            self?.queue.async { [weak self] in self?.consume(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false; self.ready = false
                if let completion = self.cleanupCompletion {
                    self.cleanupCompletion = nil; self.closing = false
                    completion(false, "后台程序已退出，无法确认临时文件是否清理。请检查系统临时目录中以 IPCCExtractor- 开头的文件夹。")
                }
                if proc.terminationStatus != 0 { self.status = "后台程序无法运行或意外退出。请重新安装应用并查看使用说明。" }
            }
        }
        do { try p.run(); process = p; writer = inputPipe.fileHandleForWriting; ready = true }
        catch { status = "无法启动后台程序：\(error.localizedDescription)。请查看使用说明。" }
    }
    private func consume(_ data: Data) {
        buffer.append(data)
        while let i = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<i]); buffer.removeSubrange(...i)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                DispatchQueue.main.async { [weak self] in self?.handle(object) }
            }
        }
    }
    private func handle(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "progress": status = msg["message"] as? String ?? "正在处理…"
        case "firmware_info":
            if closing { return }
            busy = false
            guard let path = msg["path"] as? String else { status = "无法读取固件信息"; return }
            let models = msg["models"] as? [[String: String]] ?? []
            let lines = models.map { entry -> String in
                let id = entry["id"] ?? tr("未知标识", "Unknown identifier"); let name = entry["name"] ?? ""
                return name.isEmpty ? id : "\(name)（\(id)）"
            }
            let alert = NSAlert(); alert.messageText = tr("确认固件信息", "Confirm firmware details")
            let modelNames = lines.isEmpty ? tr("清单未提供", "Not provided") : lines.joined(separator: isEnglish ? ", " : "、")
            let family = display(msg["firmware_type"] as? String ?? "未能识别")
            let version = display(msg["version"] as? String ?? "未提供")
            let build = display(msg["build"] as? String ?? "未提供")
            alert.informativeText = isEnglish ? "Device type: \(family)\nSupported models: \(modelNames)\nSystem version: \(version)\nBuild: \(build)\n\nConfirm to start scanning." : "设备类型：\(family)\n支持机型：\(modelNames)\n系统版本：\(version)\n构建版本：\(build)\n\n请确认后开始扫描。"
            alert.addButton(withTitle: tr("开始扫描", "Start Scan")); alert.addButton(withTitle: tr("取消", "Cancel"))
            if alert.runModal() == .alertFirstButtonReturn { beginScan(URL(fileURLWithPath: path)) }
            else { status = "已取消扫描；原有结果仍保留。" }
        case "cleanup_result":
            let callback = cleanupCompletion; cleanupCompletion = nil; closing = false; busy = false
            callback?(msg["ok"] as? Bool ?? false, msg["message"] as? String ?? "未知错误")
        case "warning": notice += "\n" + (msg["message"] as? String ?? "")
        case "error":
            if !closing { busy = false }
            status = "操作未完成"; notice = msg["message"] as? String ?? "未知错误"
        case "result":
            carriers = (msg["items"] as? [[String: Any]] ?? []).compactMap { d in
                guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
                return Carrier(id: id, name: name, label: d["label"] as? String ?? "", source: d["source"] as? String ?? "", issue: d["issue"] as? String ?? "", selected: d["selected"] as? Bool ?? false)
            }
            let warnings = msg["warnings"] as? [String] ?? []
            notice = warnings.joined(separator: "\n\n")
            status = carriers.isEmpty ? "未找到可读取的运营商配置。" : "扫描完成，找到 \(carriers.count) 个配置包。请勾选后导出。"
            if !closing { busy = false }
        case "exported":
            let files = msg["files"] as? [String] ?? []
            let errors = msg["errors"] as? [String] ?? []
            status = "导出完成：成功 \(files.count) 个，失败 \(errors.count) 个。"
            notice = ([files.isEmpty ? "" : "已保存：\n" + files.joined(separator: "\n"), errors.isEmpty ? "" : "未能导出：\n" + errors.joined(separator: "\n"), "已检查压缩包结构和文件内容；不代表 Apple 签名、设备兼容性或安装成功已获验证。"].filter { !$0.isEmpty }).joined(separator: "\n\n")
            if !closing { busy = false }
        default: break
        }
    }
    private func send(_ object: [String: Any]) {
        do {
            var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
            try writer?.write(contentsOf: data)
        } catch { busy = false; status = "无法与后台程序通信：\(error.localizedDescription)" }
    }
    private func beginScan(_ url: URL) {
        input = url.path; carriers = []; notice = ""; query = ""; busy = true
        status = "准备扫描…"; send(["action":"scan", "path":url.path])
    }
    func choose() {
        let panel = NSOpenPanel(); panel.title = tr("选择 iPhone 或 iPad 固件、已解密的映像或文件夹", "Choose iPhone or iPad firmware, a decrypted image, or a folder"); panel.prompt = tr("选择", "Choose")
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if url.pathExtension.lowercased() == "ipsw" {
                busy = true; status = "正在读取固件机型和版本…"; notice = ""
                send(["action":"inspect", "path":url.path])
            } else { beginScan(url) }
        }
    }
    func export() {
        let ids = carriers.filter { $0.selected }.map { $0.id }
        guard !ids.isEmpty else { notice = "请至少勾选一个可导出的运营商。"; return }
        let panel = NSOpenPanel(); panel.title = tr("选择 IPCC 导出位置", "Choose an IPCC export location")
        panel.prompt = tr("选择此位置", "Choose Location"); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            let alert = NSAlert(); alert.messageText = tr("如何保存导出的文件？", "How should the files be saved?")
            alert.informativeText = tr("可按固件版本新建文件夹，或直接保存到所选位置。无法确定版本时使用 IPCC_Export。", "Create a folder named for the firmware version, or save directly to the chosen location. IPCC_Export is used when the version is unavailable.")
            alert.addButton(withTitle: tr("新建文件夹", "Create Folder")); alert.addButton(withTitle: tr("直接保存", "Save Here")); alert.addButton(withTitle: tr("取消", "Cancel"))
            let result = alert.runModal()
            if result == .alertThirdButtonReturn { return }
            busy = true; notice = ""; status = "准备导出…"
            send(["action":"export", "ids":ids, "folder":url.path, "grouped":result == .alertFirstButtonReturn])
        }
    }
    func prepareToClose(_ completion: @escaping (Bool, String) -> Void) {
        guard ready else {
            DispatchQueue.main.async { completion(false, "后台程序未运行，无法确认临时文件是否清理。请检查系统临时目录中以 IPCCExtractor- 开头的文件夹。") }
            return
        }
        guard !closing else { return }
        closing = true; busy = true; cleanupCompletion = completion
        status = "正在等待当前操作完成并清理临时文件…"
        send(["action":"cleanup"])
    }
    func selectDefaults() { query = ""; for i in carriers.indices where carriers[i].isCommon && carriers[i].issue.isEmpty { carriers[i].selected = true } }
    func setCommon(_ identifier: String, selected: Bool) {
        for i in carriers.indices where carriers[i].name.lowercased() == identifier && carriers[i].issue.isEmpty { carriers[i].selected = selected }
    }
    func clear() { for i in carriers.indices { carriers[i].selected = false } }
    func quit() { send(["action":"quit"]) }
}

extension Notification.Name { static let showSelectedCarriers = Notification.Name("showSelectedCarriers") }

struct ContentView: View {
    @ObservedObject var model: Model
    @FocusState private var searchFocused: Bool
    var filtered: [Int] {
        model.carriers.indices.filter { i in
            let c = model.carriers[i]
            return model.query.isEmpty || c.name.localizedCaseInsensitiveContains(model.query) || c.label.localizedCaseInsensitiveContains(model.query) || model.carrierTitle(c).localizedCaseInsensitiveContains(model.query)
        }
    }
    @ViewBuilder func commonToggle(_ title: String, _ identifier: String) -> some View {
        let available = model.carriers.contains { $0.name.lowercased() == identifier && $0.issue.isEmpty }
        Toggle(title, isOn: Binding(
            get: { model.carriers.contains { $0.name.lowercased() == identifier && $0.selected } },
            set: { model.setCommon(identifier, selected: $0) }
        )).toggleStyle(.checkbox).disabled(model.busy || !available)
    }
    @ViewBuilder func carrierRow(_ i: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $model.carriers[i].selected).labelsHidden().disabled(model.busy || !model.carriers[i].issue.isEmpty)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(model.carrierTitle(model.carriers[i]))  ·  \(model.carriers[i].name)")
                Text(model.display(model.carriers[i].issue.isEmpty ? model.carriers[i].source : model.carriers[i].issue)).font(.caption).foregroundColor(model.carriers[i].issue.isEmpty ? .secondary : .red).lineLimit(2)
            }
        }.padding(.vertical, 2)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.tr("IPCC 运营商配置提取", "IPCC Carrier Bundle Extractor")).font(.title2.bold())
                    Text(model.tr("从本地 iPhone 或蜂窝版 iPad 固件中查找并批量导出配置包", "Find and export carrier bundles from iPhone or cellular iPad firmware")).foregroundColor(.secondary)
                }
                Spacer()
                Picker("Language", selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                    Text("中文").tag("zh"); Text("English").tag("en")
                }.pickerStyle(.segmented).frame(width: 140).labelsHidden()
                Button(model.tr("选择固件或文件夹…", "Choose Firmware or Folder…")) { model.choose() }.disabled(model.busy || !model.ready)
            }
            Text(model.input == "尚未选择固件或文件夹" ? model.tr("尚未选择固件或文件夹", "No firmware or folder selected") : model.input).font(.caption).foregroundColor(.secondary).lineLimit(2).textSelection(.enabled)
            Divider()
            HStack {
                HStack(spacing: 4) {
                    TextField(model.tr("搜索运营商名称或标识", "Search carrier name or identifier"), text: $model.query)
                        .textFieldStyle(.plain).focused($searchFocused).onSubmit { }
                    if !model.query.isEmpty {
                        Button {
                            model.query = ""
                            NotificationCenter.default.post(name: .showSelectedCarriers, object: nil)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                         .help(model.tr("清除搜索", "Clear search"))
                         .accessibilityLabel(model.tr("清除搜索", "Clear search"))
                    }
                }.padding(.horizontal, 8).padding(.vertical, 5)
                 .background(Color(nsColor: .textBackgroundColor))
                 .clipShape(RoundedRectangle(cornerRadius: 6))
                 .overlay(RoundedRectangle(cornerRadius: 6).stroke(searchFocused ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: searchFocused ? 2 : 1))
                 .frame(maxWidth: 320)
                Button(model.tr("全选常用", "Select Common")) { model.selectDefaults(); NotificationCenter.default.post(name: .showSelectedCarriers, object: nil) }.disabled(model.busy || model.carriers.isEmpty)
                Button(model.tr("清除勾选", "Clear Selection")) { model.clear() }.disabled(model.busy || model.carriers.isEmpty)
                Spacer()
                Text(model.isEnglish ? "Selected: \(model.carriers.filter { $0.selected }.count)" : "已选 \(model.carriers.filter { $0.selected }.count)").foregroundColor(.secondary)
            }
            HStack(spacing: 16) {
                Text(model.tr("常用：", "Common:")).foregroundColor(.secondary)
                commonToggle(model.tr("中国移动", "China Mobile"), "cmcc_cn")
                commonToggle(model.tr("中国联通", "China Unicom"), "unicom_cn")
                commonToggle(model.tr("中国电信", "China Telecom"), "chinatelecom_usim_cn")
                commonToggle(model.tr("中国广电", "China Broadnet"), "cbn_cn")
                Spacer()
            }
            ScrollViewReader { proxy in
                List {
                    Section {
                        let chosen = filtered.filter { model.carriers[$0].selected }
                        if chosen.isEmpty { Text(model.tr("尚未选择运营商", "No carriers selected")).foregroundColor(.secondary) }
                        ForEach(chosen, id: \.self) { i in carrierRow(i) }
                    } header: { Text(model.tr("已选运营商", "Selected Carriers")).id("carrier-top") }
                    Section(model.tr("其他运营商", "Other Carriers")) {
                        ForEach(filtered.filter { !model.carriers[$0].selected }, id: \.self) { i in carrierRow(i) }
                    }
                }.onReceive(NotificationCenter.default.publisher(for: .showSelectedCarriers)) { _ in
                    DispatchQueue.main.async { withAnimation { proxy.scrollTo("carrier-top", anchor: .top) } }
                }
            }.frame(minHeight: 200)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.display(model.status)).font(.callout).textSelection(.enabled)
                Spacer()
                Button(model.tr("批量导出 IPCC…", "Export Selected IPCCs…")) { model.export() }.disabled(model.busy || !model.ready || !model.carriers.contains(where: { $0.selected }))
            }
            if !model.notice.isEmpty {
                ScrollView { Text(model.display(model.notice)).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 125).padding(8).background(Color.secondary.opacity(0.09)).cornerRadius(6)
            }
            Text(model.tr("AEA 解密需要 macOS 14 及联网访问 Apple；导出文件不保证可安装。处理期间请勿强制退出。", "AEA decryption requires macOS 14 and an internet connection to Apple. Installation is not guaranteed. Do not force quit during processing."))
                .font(.caption).foregroundColor(.secondary)
        }.padding(20).frame(minWidth: 740, minHeight: 540)
    }
}

struct WindowBranding: NSViewRepresentable {
    let title: String
    static let icon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIcon-1.5", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }()
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        let desired = title
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            if window.title != desired { window.title = desired }
            if let icon = Self.icon, window.miniwindowImage !== icon { window.miniwindowImage = icon }
        }
    }
}


struct AboutView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text(model.tr("IPCC提取工具", "IPCC Extractor")).font(.title2.bold())
            Text(model.tr("版本 1.0 Beta", "Version 1.0 Beta")).foregroundColor(.secondary)
            Divider().padding(.vertical, 4)
            Text(model.tr("从 iPhone 和蜂窝版 iPad 固件中提取运营商配置", "Extract carrier bundles from iPhone and cellular iPad firmware"))
                .multilineTextAlignment(.center).foregroundColor(.secondary)
            Link(model.tr("GitHub 项目主页", "GitHub Project"), destination: URL(string: "https://github.com/Today1314/IPCC-Extractor")!)
                .padding(.top, 3)
        }.padding(26).frame(width: 360)
         .background(WindowBranding(title: model.tr("关于 IPCC提取工具", "About IPCC Extractor")))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: Model?
    private var aboutWindow: NSWindow?
    func showAbout(model: Model) {
        if aboutWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AboutView(model: model))
            window.center()
            aboutWindow = window
        }
        aboutWindow?.title = model.tr("关于 IPCC提取工具", "About IPCC Extractor")
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    private func loadApplicationIcon() {
        if let url = Bundle.main.url(forResource: "AppIcon-1.5", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
            NSApplication.shared.dockTile.display()
        }
    }
    func applicationWillFinishLaunching(_ notification: Notification) { loadApplicationIcon() }
    func applicationDidFinishLaunching(_ notification: Notification) { loadApplicationIcon() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = model else { return .terminateNow }
        finishTermination(sender, model: model)
        return .terminateLater
    }
    private func finishTermination(_ sender: NSApplication, model: Model) {
        model.prepareToClose { [weak self] ok, message in
            if ok { sender.reply(toApplicationShouldTerminate: true); return }
            let alert = NSAlert(); alert.messageText = model.tr("临时文件未能清理", "Temporary files could not be cleaned")
            alert.informativeText = model.display(message) + model.tr("\n\n请排除占用或权限问题后重试；也可以仍然退出并保留临时文件。", "\n\nResolve any access or permission issues and retry, or quit and keep the temporary files.")
            alert.addButton(withTitle: model.tr("重试清理", "Retry Cleanup")); alert.addButton(withTitle: model.tr("返回程序", "Return to App")); alert.addButton(withTitle: model.tr("仍然退出", "Quit Anyway"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: self?.finishTermination(sender, model: model)
            case .alertThirdButtonReturn: sender.reply(toApplicationShouldTerminate: true)
            default: sender.reply(toApplicationShouldTerminate: false)
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { model?.quit() }
}
@main struct IPCCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = Model()
    var body: some Scene {
        WindowGroup(model.tr("IPCC提取工具", "IPCC Extractor")) {
            ContentView(model: model)
                .background(WindowBranding(title: model.tr("IPCC提取工具", "IPCC Extractor")))
                .onAppear { delegate.model = model }
        }.commands {
            CommandGroup(replacing: .appInfo) {
                Button(model.tr("关于 IPCC提取工具", "About IPCC Extractor")) { delegate.showAbout(model: model) }
            }
        }
    }
}
