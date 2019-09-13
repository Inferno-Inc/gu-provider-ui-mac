import Cocoa
import Socket

struct NodeInfo: Decodable {
    var name: String
    var address: String
    var description: String
    enum CodingKeys: String, CodingKey {
        case name = "Host name", address = "Addresses", description = "Description"
    }
    func nodeId() -> String? {
        let lines = description.split(separator: "\n")
        for line in lines {
            let parts = line.split(separator: "=")
            if parts.count <= 1 { return nil } else { return String(parts[1]) }
        }
        return nil
    }
}

struct SavedNodeInfo: Decodable {
    var name: String
    var address: String
    var nodeId: String
    enum CodingKeys: String, CodingKey {
        case name = "host_name", address, nodeId = "node_id"
    }
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDelegate, NSTableViewDataSource {

    @IBOutlet weak var window: NSWindow!
    @IBOutlet weak var addHubPanel: NSPanel!
    @IBOutlet weak var statusBarMenu: NSMenu!
    @IBOutlet weak var autoModeButton: NSPopUpButton!
    @IBOutlet weak var hubListTable: NSTableView!
    @IBOutlet weak var hubIP: NSTextField!
    @IBOutlet weak var hubPort: NSTextField!
    @IBOutlet weak var statusField: NSTextField!

    let statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    let socketPathGlobal = "/var/run/golemu/gu-provider.socket"
    let socketPathUserHome = "Library/Application Support/network.Golem.Golem-Unlimited/run/gu-provider.socket"
    var unixSocketPath = ""
    var serverProcessHandle: Process?
    var localServerRequestTimer: Timer?
    var connected = false

    var nodes: [NodeInfo] = []
    var hubStatuses = [String: String]()
    var nodeModes: [Int] = []

    struct ServerResponse: Decodable {
        let envs: [String:String]
    }

    func updateConnectionStatus() {
        var hubStatusesNew = [String: String]()
        guard let connectionList = getHTTPBodyFromUnixSocketAsData(path: unixSocketPath, method: "GET", query: "/connections/list/all", body: "") else {
            NSLog("Cannot connect or invalid response (/connections/list/all)")
            return
        }
        let connections = try! JSONDecoder().decode([[String]].self, from: connectionList)
        for c in connections {
            hubStatusesNew[c[0]] = c[1]
        }
        if hubStatusesNew != hubStatuses {
            hubStatuses = hubStatusesNew
            hubListTable.reloadData()
            NSLog("Changed")
        }
    }

    @objc func updateServerStatus() {
        if let status = getHTTPBodyFromUnixSocket(path: unixSocketPath, method: "GET", query: "/status?timeout=5", body: "") {
            if let json = try? JSONDecoder().decode(ServerResponse.self, from:status.data(using: .utf8)!) {
                let status = json.envs["hostDirect"] ?? "Error"
                let oldConnected = self.connected
                self.connected = status == "Ready"
                if !oldConnected && self.connected { DispatchQueue.main.async { self.reloadHubList() } }
                if self.connected { updateConnectionStatus() }
                self.setMenuBarText(text: self.connected ? "" : "!")
                statusField.stringValue = "Golem Unlimited Provider Status: " + status
                return
            }
        }
        self.setMenuBarText(text: "!")
        statusField.stringValue = "No Connection"
    }

    func requestHTTPFromUnixSocket(path: String, method: String, query: String, body: String) -> String? {
        do {
            let socket = try Socket.create(family: .unix, type: Socket.SocketType.stream, proto: .unix)
            try socket.setReadTimeout(value: 2500)
            try socket.setWriteTimeout(value: 2500)
            if (try? socket.connect(to: path)) == nil { socket.close(); return nil }
            var additional_headers = ""
            if body != "" {
                additional_headers += "Content-length: " + String(body.lengthOfBytes(using: .utf8)) + "\r\n"
                additional_headers += "Content-type: application/json\r\n"
            }
            let message = method + " " + query + " HTTP/1.0\r\n" + additional_headers + "\r\n" + body
            let k = try? socket.write(from: message)
            if k == nil || k != message.utf8.count {
                socket.close()
                return nil
            }
            var result = ""
            while true {
                do {
                    let str = try socket.readString()
                    if str == nil { break } else { result += str! }
                } catch {
                    break
                }
            }
            socket.close()
            return result
        } catch {
            return nil
        }
    }

    func getHTTPBodyFromUnixSocket(path: String, method: String, query: String, body: String) -> String? {
        guard let response = requestHTTPFromUnixSocket(path: path, method: method, query: query, body: body) else { return nil }
        let body = response.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        return body
    }

    func getHTTPBodyFromUnixSocketAsData(path: String, method: String, query: String, body: String) -> Data? {
        return getHTTPBodyFromUnixSocket(path: path, method: method, query: query, body: body)?.data(using: .utf8, allowLossyConversion: false)
    }

    func configureUnixSocketPath() {
        let localPathInHome = FileManager.default.homeDirectoryForCurrentUser.path + "/" + socketPathUserHome
        unixSocketPath = FileManager.default.fileExists(atPath: localPathInHome) ? localPathInHome : socketPathGlobal
        NSLog("Using unix domain socket at: %@", unixSocketPath)
    }

    func launchServerPolling() {
        localServerRequestTimer = Timer.scheduledTimer(timeInterval: 1, target: self,
                                                       selector: #selector(updateServerStatus), userInfo: nil, repeats: true)
        localServerRequestTimer?.fire()
    }

    func setMenuBarText(text: String) {
        DispatchQueue.main.async {
            self.statusBarItem.button!.title = text
        }
    }

    func addStatusBarMenu() {
        statusBarItem.button?.image = NSImage.init(named: "GolemMenuIcon")
        statusBarItem.button?.image?.isTemplate = true
        statusBarItem.button?.imagePosition = NSControl.ImagePosition.imageLeft
        statusBarItem.menu = statusBarMenu
    }

    @IBAction func showConfigurationWindow(_ sender: Any) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(self)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableColumn?.identifier.rawValue != "Selected" && tableColumn?.identifier.rawValue != "ConnectionMode" {
            let cell = tableView.makeView(withIdentifier:NSUserInterfaceItemIdentifier(tableColumn!.identifier.rawValue + ""), owner: nil) as! NSTableCellView
            let node = nodes[row]
            cell.textField?.stringValue = [node.name, "", hubStatuses[node.address] ?? "-", node.address, node.nodeId() ?? ""][tableView.tableColumns.firstIndex(of: tableColumn!)!]
            return cell
        } else {
            let cell = tableView.makeView(withIdentifier:NSUserInterfaceItemIdentifier("ConnectionMode"), owner: nil) as! NSTableCellView
            (cell.viewWithTag(100) as! NSPopUpButton).selectItem(at: nodeModes[row])
            (cell.viewWithTag(100) as! NSPopUpButton).action = #selector(AppDelegate.connectionModeChanged)
            return cell
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        return nodes.count
    }

    func dataToInt(data: Data) -> Int? {
        let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespaces).lowercased()
        if str == "false" { return 0 }
        if str == "true" { return 1 }
        return Int(str ?? "0")
    }

    func reloadHubList() {
        guard let auto = getHTTPBodyFromUnixSocketAsData(path: unixSocketPath, method: "GET", query: "/nodes/auto", body: "") else {
            NSLog("Cannot connect or invalid response (/nodes/auto)")
            return
        }
        autoModeButton.selectItem(at: dataToInt(data: auto) ?? 0)
        var all: Set<String> = []
        guard let data = getHTTPBodyFromUnixSocketAsData(path: unixSocketPath, method: "GET", query: "/lan/list", body: "") else { return }
        nodes = try! JSONDecoder().decode([NodeInfo].self, from: data)
        nodeModes = []
        for node in nodes {
            guard let status = getHTTPBodyFromUnixSocketAsData(path: unixSocketPath, method: "GET", query: "/nodes/" + node.nodeId()!, body: "")
                else { return }
            nodeModes.append(dataToInt(data: status)!)
            all.insert(node.nodeId()!)
        }
        guard let saved_nodes_data = getHTTPBodyFromUnixSocketAsData(path: unixSocketPath, method: "GET", query: "/nodes?saved", body: "")
            else { return }
        let saved_nodes = try! JSONDecoder().decode([SavedNodeInfo].self, from: saved_nodes_data)
        for node in saved_nodes {
            if !all.contains(node.nodeId) {
                nodes.append(NodeInfo(name: node.name, address: node.address, description: "node_id=" + node.nodeId))
                guard let status = getHTTPBodyFromUnixSocketAsData(path: unixSocketPath, method: "GET", query: "/nodes/" + node.nodeId, body: "") else { return }
                nodeModes.append(dataToInt(data: status)!)
                all.insert(node.nodeId)
            }
        }
        hubListTable.reloadData()
    }

    struct AddressHostNameAccessLevel : Encodable {
        var address: String
        var hostName: String
        var accessLevel: Int
    }

    @objc func connectionModeChanged(sender: NSPopUpButton) {
        let row = hubListTable.row(for:sender)
        let encodedBody = String(data: try! JSONEncoder().encode(AddressHostNameAccessLevel(address: nodes[row].address, hostName: nodes[row].name, accessLevel: sender.indexOfSelectedItem)), encoding: .utf8)!
        nodeModes[row] = sender.indexOfSelectedItem
        let _ = getHTTPBodyFromUnixSocket(path: unixSocketPath,
                                          method: sender.indexOfSelectedItem > 0 ? "PUT" : "DELETE",
                                          query: "/nodes/" + nodes[row].nodeId()!,
                                          body: encodedBody)
        let _ = getHTTPBodyFromUnixSocket(path: unixSocketPath, method: "POST", query: "/connections/" + (sender.indexOfSelectedItem > 0 ? "connect" : "disconnect") + "?save=1", body: "[\"" + nodes[row].address + "\"]")
    }

    @IBAction func addHubPressed(_ sender: NSButton) {
        addHubPanel.makeKeyAndOrderFront(self)
    }

    @IBAction func refreshPressed(_ sender: NSButton) {
        reloadHubList()
    }

    @IBAction func autoConnectChanged(_ sender: NSPopUpButton) {
        let _ = getHTTPBodyFromUnixSocket(path: unixSocketPath, method: sender.indexOfSelectedItem > 0 ? "PUT" : "DELETE", query: "/nodes/auto", body: "{\"accessLevel\":" + String(sender.indexOfSelectedItem) + "}")
        let _ = getHTTPBodyFromUnixSocket(path: unixSocketPath, method: "PUT", query: "/connections/mode/" + (sender.indexOfSelectedItem > 0 ? "auto" : "manual") + "?save=1", body: "")
    }

    func showError(message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @IBAction func addEnteredHub(_ sender: NSButton) {
        let ipPort = hubIP.stringValue + ":" + hubPort.stringValue
        // TODO check IP
        let urlString = "http://" + ipPort + "/node_id/"
        URLSession.shared.dataTask(with: URL(string: urlString)!) { (data, res, err) in
            if data == nil || err != nil { self.showError(message: "Cannot connect to " + ipPort); return }
            let nodeIdAndHostName = String(data: data!, encoding: .utf8)!.split(separator: " ")
            if nodeIdAndHostName.count != 2 || (res as! HTTPURLResponse).statusCode != 200 {
                self.showError(message: "Bad answer from " + urlString + ".")
                return
            }
            let encodedBody = String(data: try! JSONEncoder().encode(AddressHostNameAccessLevel(address: ipPort, hostName: String(nodeIdAndHostName[1]), accessLevel: 1)), encoding: .utf8)!
            let _ = self.getHTTPBodyFromUnixSocket(path: self.unixSocketPath,
                                                   method: "PUT",
                                                   query: "/nodes/" + String(nodeIdAndHostName[0]),
                                                   body: encodedBody)
            let _ = self.getHTTPBodyFromUnixSocket(path: self.unixSocketPath,
                                                   method: "POST", query: "/connections/connect?save=1", body: "[\"" + ipPort + "\"]")
            DispatchQueue.main.async {
                self.reloadHubList()
                self.hubIP.stringValue = ""
                self.addHubPanel.orderOut(self)
            }
        }.resume()
    }

    func getPList(label: String, runAtLoad: Bool, keepAlive: Bool, exec: String, args: [String]?) -> String {
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            """
            + "<key>Label</key><string>" + label + "</string>"
            + (args == nil ? "<key>Program</key><string>" + exec + "</string>"
                : "<key>ProgramArguments</key><array><string>" + exec + "</string>" + args!.map({ "<string>" + $0 + "</string>"}).joined() + "</array>")
            + (runAtLoad ? "<key>RunAtLoad</key><true/>" : "")
            + (keepAlive ? "<key>KeepAlive</key><true/>" : "")
            + "</dict></plist>"
    }
    
    func configureAutomaticStart() {
        let appDir = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        let launchDir = try! FileManager.default
            .url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        if !FileManager.default.fileExists(atPath: launchDir.path) {
            try? FileManager.default.createDirectory(at: launchDir, withIntermediateDirectories: true, attributes: nil)
        }
        /* create provider server launchd plist */
        let execLocation = appDir
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("gu-provider", isDirectory: false)
        let providerLaunchFileContent = getPList(label: "network.golem.gu-provider", runAtLoad: true,
                                                 keepAlive: true, exec: execLocation.path,
                                                 args: ["-vv", "server", "run", "--user"])
        let launchFileProvider = launchDir.appendingPathComponent("network.golem.gu-provider.plist", isDirectory: false)
        try? providerLaunchFileContent.write(to: launchFileProvider, atomically: true, encoding: .utf8)
        /* run provider server */
        let server = Process()
        server.launchPath = "/bin/launchctl"
        server.arguments = ["load", launchFileProvider.path]
        server.environment = ProcessInfo.processInfo.environment
        server.launch()
        /* create provider UI launchd plist */
        let execLocationUI = appDir.appendingPathComponent("Golem Unlimited Provider", isDirectory: false)
        let providerUILaunchFileContent = getPList(label: "network.golem.gu-provider-ui", runAtLoad: true,
                                                   keepAlive: false, exec: execLocationUI.path, args: nil)
        let launchFileProviderUI = launchDir.appendingPathComponent("network.golem.gu-provider-ui.plist", isDirectory: false)
        try? providerUILaunchFileContent.write(to: launchFileProviderUI, atomically: true, encoding: .utf8)
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        configureAutomaticStart()
        addHubPanel.isFloatingPanel = true
        addStatusBarMenu()
        configureUnixSocketPath()
        launchServerPolling()
        reloadHubList()
        if !UserDefaults.standard.bool(forKey: "firstRun") {
            UserDefaults.standard.set(true, forKey: "firstRun")
            showConfigurationWindow(self)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        localServerRequestTimer?.invalidate()
        serverProcessHandle?.terminate()
    }

    @IBAction func quitApp(_ sender: Any) {
        NSApplication.shared.terminate(self)
    }

}
