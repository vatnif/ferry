import XCTest

/// M4 smoke tests for the connection manager. Each test runs against an
/// isolated store (FERRY_DATA_DIR → temp dir) and a test Keychain service,
/// so user data is never touched (docs/TESTING.md).
final class FerryUITests: XCTestCase {
    @MainActor
    private func launchIsolatedApp(extraEnvironment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        let dataDir = NSTemporaryDirectory() + "ferry-uitests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        app.launchEnvironment["FERRY_DATA_DIR"] = dataDir
        app.launchEnvironment["FERRY_KEYCHAIN_SERVICE"] = "com.gfragos.Ferry.uitests"
        for (key, value) in extraEnvironment { app.launchEnvironment[key] = value }
        app.launch()
        return app
    }

    /// After connecting to a server for the first time (empty known_hosts in the
    /// isolated data dir), Ferry shows the TOFU host-key prompt (M11). Trust it
    /// so the connection can proceed. Safe to call when no prompt appears.
    @MainActor
    private func trustHostKeyIfPrompted(_ app: XCUIApplication) {
        let trust = app.buttons["hostKey.trust"]
        if trust.waitForExistence(timeout: 10) {
            trust.click()
        }
    }

    @MainActor
    func testAppLaunchesWithSidebarAndEmptyState() throws {
        let app = launchIsolatedApp()
        XCTAssertTrue(app.staticTexts["Connections"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No Connection Selected"].exists)
    }

    @MainActor
    func testNewConnectionSheetOpensAndCancels() throws {
        let app = launchIsolatedApp()
        app.buttons["sidebar.newConnection"].click()
        let nameField = app.textFields["editor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["editor.test"].exists)
        app.buttons["editor.cancel"].click()
        XCTAssertFalse(nameField.waitForExistence(timeout: 2))
    }

    /// True when the Docker SFTP test server answers on 2222.
    private var sftpServerUp: Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(2222).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// End-to-end walk-through (M7 + M8): create a connection to the Docker
    /// SFTP server through the UI, connect with the password prompt, browse,
    /// download a file through the transfer queue, and disconnect.
    @MainActor
    func testConnectBrowseAndDownloadAgainstTestServer() throws {
        try XCTSkipUnless(sftpServerUp, "SFTP test server not running — testinfra/start.sh")
        let app = launchIsolatedApp()
        let downloadDir = NSTemporaryDirectory() + "ferry-uitests-dl-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: downloadDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: downloadDir) }

        // Create the connection (password left empty → prompt at connect;
        // local pane starts in our temp dir so the download is observable).
        app.buttons["sidebar.newConnection"].click()
        let nameField = app.textFields["editor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click(); nameField.typeText("docker-sftp")
        let hostField = app.textFields["editor.host"]
        hostField.click(); hostField.typeText("127.0.0.1")
        let portField = app.textFields["editor.port"]
        portField.click()
        portField.typeKey("a", modifierFlags: .command)
        portField.typeText("2222")
        let userField = app.textFields["editor.username"]
        userField.click(); userField.typeText("ferry")
        let localStartField = app.textFields["editor.localStart"]
        localStartField.click(); localStartField.typeText(downloadDir)
        app.buttons["editor.save"].click()

        // Connect → password prompt appears; type the password.
        let connectButton = app.buttons["detail.connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
        connectButton.click()
        let passwordField = app.secureTextFields["passwordPrompt.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        passwordField.click(); passwordField.typeText("ferrypass")
        app.buttons["passwordPrompt.connect"].click()

        // First contact: trust the server's host key (TOFU, M11).
        trustHostKeyIfPrompted(app)

        // Connected: status bar + remote listing shows the server's dirs.
        XCTAssertTrue(app.staticTexts["browser.status.connected"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["upload"].waitForExistence(timeout: 10),
                      "remote pane should list the SFTP server's upload directory")

        // M8: navigate into fixtures, select hello.txt, download via the queue.
        let fixturesRow = app.staticTexts["fixtures"].firstMatch
        XCTAssertTrue(fixturesRow.waitForExistence(timeout: 10))
        fixturesRow.doubleClick()
        var remoteFile = app.staticTexts["hello.txt"].firstMatch
        if !remoteFile.waitForExistence(timeout: 8) {
            // The table can relayout mid-click right after connect — retry once.
            app.staticTexts["fixtures"].firstMatch.doubleClick()
            remoteFile = app.staticTexts["hello.txt"].firstMatch
            XCTAssertTrue(remoteFile.waitForExistence(timeout: 10))
        }
        remoteFile.click()
        let downloadButton = app.buttons["browser.download"]
        XCTAssertTrue(downloadButton.isEnabled)
        downloadButton.click()

        XCTAssertTrue(app.staticTexts["DONE"].firstMatch.waitForExistence(timeout: 15),
                      "queue dock should show the completed download")
        let landed = FileManager.default.fileExists(atPath: downloadDir + "/hello.txt")
        XCTAssertTrue(landed, "downloaded file must exist in the local start dir")

        // Disconnect returns to the summary.
        app.buttons["browser.disconnect"].click()
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
    }

    /// M14: with an SSH connection live, the Tunnels toolbar button opens the
    /// tunnel manager (screen 4); adding a local forward through the editor
    /// lands a row in the table.
    @MainActor
    func testTunnelManagerOpensAndAddsTunnel() throws {
        try XCTSkipUnless(sftpServerUp, "SFTP test server not running — testinfra/start.sh")
        let app = launchIsolatedApp()

        app.buttons["sidebar.newConnection"].click()
        let nameField = app.textFields["editor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click(); nameField.typeText("docker-sftp")
        let hostField = app.textFields["editor.host"]
        hostField.click(); hostField.typeText("127.0.0.1")
        let portField = app.textFields["editor.port"]
        portField.click(); portField.typeKey("a", modifierFlags: .command); portField.typeText("2222")
        let userField = app.textFields["editor.username"]
        userField.click(); userField.typeText("ferry")
        app.buttons["editor.save"].click()

        let connectButton = app.buttons["detail.connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
        connectButton.click()
        let passwordField = app.secureTextFields["passwordPrompt.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        passwordField.click(); passwordField.typeText("ferrypass")
        app.buttons["passwordPrompt.connect"].click()
        trustHostKeyIfPrompted(app)
        XCTAssertTrue(app.staticTexts["browser.status.connected"].waitForExistence(timeout: 15))

        // Open the tunnel manager from the toolbar.
        let tunnelsButton = app.buttons["browser.tunnels"]
        XCTAssertTrue(tunnelsButton.waitForExistence(timeout: 5))
        tunnelsButton.click()

        // Empty state → Add opens the editor.
        let addButton = app.buttons["tunnels.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.click()

        // Fill a local forward (default type Local, listen host prefilled).
        let listenPort = app.textFields["tunnelEditor.listenPort"]
        XCTAssertTrue(listenPort.waitForExistence(timeout: 5))
        listenPort.click(); listenPort.typeText("15432")
        let destHost = app.textFields["tunnelEditor.destHost"]
        destHost.click(); destHost.typeText("db.internal")
        let destPort = app.textFields["tunnelEditor.destPort"]
        destPort.click(); destPort.typeText("5432")
        app.buttons["tunnelEditor.save"].click()

        // The new tunnel shows in the table (Listen column).
        XCTAssertTrue(app.staticTexts["127.0.0.1:15432"].waitForExistence(timeout: 5),
                      "the added tunnel should appear in the manager table")
        XCTAssertTrue(app.staticTexts["db.internal:5432"].exists)
    }

    /// M11: first contact with a server shows the TOFU host-key dialog with a
    /// fingerprint; trusting it lets the connection proceed.
    @MainActor
    func testHostKeyTrustPromptOnFirstConnect() throws {
        try XCTSkipUnless(sftpServerUp, "SFTP test server not running — testinfra/start.sh")
        let app = launchIsolatedApp()

        app.buttons["sidebar.newConnection"].click()
        let nameField = app.textFields["editor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click(); nameField.typeText("docker-sftp")
        let hostField = app.textFields["editor.host"]
        hostField.click(); hostField.typeText("127.0.0.1")
        let portField = app.textFields["editor.port"]
        portField.click(); portField.typeKey("a", modifierFlags: .command); portField.typeText("2222")
        let userField = app.textFields["editor.username"]
        userField.click(); userField.typeText("ferry")
        app.buttons["editor.save"].click()

        let connectButton = app.buttons["detail.connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
        connectButton.click()
        let passwordField = app.secureTextFields["passwordPrompt.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        passwordField.click(); passwordField.typeText("ferrypass")
        app.buttons["passwordPrompt.connect"].click()

        // The TOFU sheet appears with the offered fingerprint and a trust action.
        let trust = app.buttons["hostKey.trust"]
        XCTAssertTrue(trust.waitForExistence(timeout: 10), "host-key TOFU prompt should appear")
        let fingerprint = app.staticTexts["hostKey.offered"]
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 5))
        // A selectable Text may expose its string as value rather than label.
        let shown = fingerprint.label + " " + String(describing: fingerprint.value ?? "")
        XCTAssertTrue(shown.contains("SHA256:"),
                      "fingerprint box should show the SHA256 (got \(shown))")
        trust.click()

        XCTAssertTrue(app.staticTexts["browser.status.connected"].waitForExistence(timeout: 15))
    }

    /// M10: connect, then rename and delete a file in the LOCAL pane via the
    /// row context menu. Uses the local pane (no server writes), but still
    /// exercises the real browser, so a live connection is required.
    @MainActor
    func testRenameAndDeleteFileInLocalPane() throws {
        try XCTSkipUnless(sftpServerUp, "SFTP test server not running — testinfra/start.sh")
        let workDir = NSTemporaryDirectory() + "ferry-uitests-ops-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: workDir) }
        let original = workDir + "/target.txt"
        FileManager.default.createFile(atPath: original, contents: Data("hi".utf8))

        let app = launchIsolatedApp()
        app.buttons["sidebar.newConnection"].click()
        let nameField = app.textFields["editor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click(); nameField.typeText("docker-sftp")
        let hostField = app.textFields["editor.host"]
        hostField.click(); hostField.typeText("127.0.0.1")
        let portField = app.textFields["editor.port"]
        portField.click(); portField.typeKey("a", modifierFlags: .command); portField.typeText("2222")
        let userField = app.textFields["editor.username"]
        userField.click(); userField.typeText("ferry")
        let localStartField = app.textFields["editor.localStart"]
        localStartField.click(); localStartField.typeText(workDir)
        app.buttons["editor.save"].click()

        let connectButton = app.buttons["detail.connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
        connectButton.click()
        let passwordField = app.secureTextFields["passwordPrompt.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        passwordField.click(); passwordField.typeText("ferrypass")
        app.buttons["passwordPrompt.connect"].click()
        trustHostKeyIfPrompted(app)

        XCTAssertTrue(app.staticTexts["browser.status.connected"].waitForExistence(timeout: 15))

        // Rename target.txt → renamed.txt via the context menu.
        let row = app.staticTexts["target.txt"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "local pane should list the seeded file")
        row.rightClick()
        app.menuItems["Rename…"].click()
        // The alert's text field auto-focuses; select-all and overwrite it.
        let renameButton = app.windows.buttons["Rename"].firstMatch
        XCTAssertTrue(renameButton.waitForExistence(timeout: 5))
        app.typeKey("a", modifierFlags: .command)
        app.typeText("renamed.txt")
        renameButton.click()

        XCTAssertTrue(app.staticTexts["renamed.txt"].firstMatch.waitForExistence(timeout: 10),
                      "renamed file should appear in the pane")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original),
                       "the original name should be gone on disk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workDir + "/renamed.txt"))

        // Delete renamed.txt via the context menu + confirmation.
        app.staticTexts["renamed.txt"].firstMatch.rightClick()
        // "Delete…" (ellipsis) is unique — AppKit's standard Edit▸Delete has none.
        app.menuItems["Delete…"].click()
        let deleteButton = app.windows.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.click()

        XCTAssertFalse(app.staticTexts["renamed.txt"].firstMatch.waitForExistence(timeout: 8),
                       "deleted file should disappear from the pane")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDir + "/renamed.txt"))
    }

    @MainActor
    func testCreateConnectionShowsInSidebarAndDetail() throws {
        let app = launchIsolatedApp()
        app.buttons["sidebar.newConnection"].click()

        let nameField = app.textFields["editor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click()
        nameField.typeText("prod-web-01")
        let hostField = app.textFields["editor.host"]
        hostField.click()
        hostField.typeText("203.0.113.14")
        let userField = app.textFields["editor.username"]
        userField.click()
        userField.typeText("deploy")

        let saveButton = app.buttons["editor.save"]
        XCTAssertTrue(saveButton.isEnabled, "form with name+host+user must be savable")
        saveButton.click()

        // New profile is auto-selected: row in sidebar + summary in detail.
        XCTAssertTrue(app.staticTexts["prod-web-01"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["deploy@203.0.113.14:22"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["detail.connect"].exists)
    }

    /// M11 checkpoint B: importing from `~/.ssh/config` (pointed at a fixture via
    /// FERRY_SSH_CONFIG) surfaces the parsed hosts in a checklist and adds the
    /// chosen ones to the sidebar under an "Imported" folder.
    @MainActor
    func testImportFromSSHConfigAddsProfiles() throws {
        let configPath = NSTemporaryDirectory() + "ferry-ssh-config-\(UUID().uuidString)"
        let config = """
        Host *
            User default

        Host imported-box
            HostName imported.example.com
            User admin
            Port 2222
        """
        try config.write(toFile: configPath, atomically: true, encoding: .utf8)

        let app = launchIsolatedApp(extraEnvironment: ["FERRY_SSH_CONFIG": configPath])
        XCTAssertTrue(app.staticTexts["Connections"].waitForExistence(timeout: 10))

        // Drive the canonical entry: File ▸ Import from SSH Config… (the toolbar
        // control mirrors this but can fold into the toolbar overflow).
        app.menuBars.menuBarItems["File"].click()
        let configItem = app.menuItems["Import from SSH Config…"]
        XCTAssertTrue(configItem.waitForExistence(timeout: 5))
        configItem.click()

        // The checklist appears with the concrete host checked (wildcard block
        // skipped). The host name is folded into the checkbox's label.
        let importButton = app.buttons["sshImport.import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        XCTAssertTrue(app.checkBoxes.containing(
            NSPredicate(format: "label CONTAINS %@", "imported-box")).firstMatch.exists)
        importButton.click()

        // Success notice (dismiss; OK is duplicated on the Touch Bar), then the
        // folder + profile appear in the sidebar.
        let ok = app.windows.buttons["OK"].firstMatch
        if ok.waitForExistence(timeout: 5) { ok.click() }
        XCTAssertTrue(app.staticTexts["Imported"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["imported-box"].firstMatch.waitForExistence(timeout: 5))
    }

    /// True when the Docker plaintext FTP test server answers on 2121.
    private var ftpServerUp: Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(2121).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// Selects a protocol segment in the editor's segmented control (exposed as
    /// a radio button on macOS, with a plain-button fallback).
    @MainActor
    private func selectProtocol(_ app: XCUIApplication, _ label: String) {
        let radio = app.radioButtons[label]
        if radio.waitForExistence(timeout: 3) { radio.click(); return }
        let button = app.buttons[label]
        if button.waitForExistence(timeout: 3) { button.click() }
    }

    /// M12 end-to-end: create an FTP connection to the Docker FTP server, pick
    /// the FTP protocol, connect with the password prompt (no host-key TOFU for
    /// FTP), browse into fixtures, download a file through the queue, disconnect.
    @MainActor
    func testConnectBrowseAndDownloadAgainstFTPServer() throws {
        try XCTSkipUnless(ftpServerUp, "FTP test server not running — testinfra/start.sh")
        let app = launchIsolatedApp()
        let downloadDir = NSTemporaryDirectory() + "ferry-uitests-ftp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: downloadDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: downloadDir) }

        app.buttons["sidebar.newConnection"].click()
        let nameField = app.textFields["editor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click(); nameField.typeText("docker-ftp")

        selectProtocol(app, "FTP")

        let hostField = app.textFields["editor.host"]
        hostField.click(); hostField.typeText("127.0.0.1")
        let portField = app.textFields["editor.port"]
        portField.click(); portField.typeKey("a", modifierFlags: .command); portField.typeText("2121")
        let userField = app.textFields["editor.username"]
        userField.click(); userField.typeText("ferry")
        let localStartField = app.textFields["editor.localStart"]
        localStartField.click(); localStartField.typeText(downloadDir)
        app.buttons["editor.save"].click()

        let connectButton = app.buttons["detail.connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
        connectButton.click()
        let passwordField = app.secureTextFields["passwordPrompt.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        passwordField.click(); passwordField.typeText("ferrypass")
        app.buttons["passwordPrompt.connect"].click()

        // Connected: the remote pane lists the FTP home (/ftp/ferry → fixtures).
        XCTAssertTrue(app.staticTexts["browser.status.connected"].waitForExistence(timeout: 15))
        let fixturesRow = app.staticTexts["fixtures"].firstMatch
        XCTAssertTrue(fixturesRow.waitForExistence(timeout: 10),
                      "remote pane should list the FTP server's fixtures directory")
        fixturesRow.doubleClick()

        var remoteFile = app.staticTexts["hello.txt"].firstMatch
        if !remoteFile.waitForExistence(timeout: 8) {
            app.staticTexts["fixtures"].firstMatch.doubleClick()
            remoteFile = app.staticTexts["hello.txt"].firstMatch
            XCTAssertTrue(remoteFile.waitForExistence(timeout: 10))
        }
        remoteFile.click()
        let downloadButton = app.buttons["browser.download"]
        XCTAssertTrue(downloadButton.isEnabled)
        downloadButton.click()

        XCTAssertTrue(app.staticTexts["DONE"].firstMatch.waitForExistence(timeout: 20),
                      "queue dock should show the completed download")
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadDir + "/hello.txt"),
                      "downloaded file must exist in the local start dir")

        app.buttons["browser.disconnect"].click()
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
    }

    /// True when the Docker SSH/SCP test server answers on 2223.
    private var scpServerUp: Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(2223).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// M13 end-to-end: create an SCP connection to the exec-capable Docker SSH
    /// server (:2223), connect with the password prompt + host-key TOFU (SCP
    /// rides the SSH stack), browse into fixtures, download a file through the
    /// queue, disconnect. SCP is macOS 15+, which this test host satisfies.
    @MainActor
    func testConnectBrowseAndDownloadAgainstSCPServer() throws {
        try XCTSkipUnless(scpServerUp, "SSH/SCP test server not running — testinfra/start.sh")
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("SCP requires macOS 15+")
        }
        let app = launchIsolatedApp()
        let downloadDir = NSTemporaryDirectory() + "ferry-uitests-scp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: downloadDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: downloadDir) }

        app.buttons["sidebar.newConnection"].click()
        let nameField = app.textFields["editor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click(); nameField.typeText("docker-scp")

        selectProtocol(app, "SCP")

        let hostField = app.textFields["editor.host"]
        hostField.click(); hostField.typeText("127.0.0.1")
        let portField = app.textFields["editor.port"]
        portField.click(); portField.typeKey("a", modifierFlags: .command); portField.typeText("2223")
        let userField = app.textFields["editor.username"]
        userField.click(); userField.typeText("ferry")
        let localStartField = app.textFields["editor.localStart"]
        localStartField.click(); localStartField.typeText(downloadDir)
        app.buttons["editor.save"].click()

        let connectButton = app.buttons["detail.connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
        connectButton.click()
        let passwordField = app.secureTextFields["passwordPrompt.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        passwordField.click(); passwordField.typeText("ferrypass")
        app.buttons["passwordPrompt.connect"].click()

        // First contact: trust the server's host key (TOFU, M11).
        trustHostKeyIfPrompted(app)

        // Connected: the remote pane lists the SSH home (/home/ferry → fixtures).
        XCTAssertTrue(app.staticTexts["browser.status.connected"].waitForExistence(timeout: 20))
        let fixturesRow = app.staticTexts["fixtures"].firstMatch
        XCTAssertTrue(fixturesRow.waitForExistence(timeout: 10),
                      "remote pane should list the SCP server's fixtures directory")
        fixturesRow.doubleClick()

        var remoteFile = app.staticTexts["hello.txt"].firstMatch
        if !remoteFile.waitForExistence(timeout: 8) {
            app.staticTexts["fixtures"].firstMatch.doubleClick()
            remoteFile = app.staticTexts["hello.txt"].firstMatch
            XCTAssertTrue(remoteFile.waitForExistence(timeout: 10))
        }
        remoteFile.click()
        let downloadButton = app.buttons["browser.download"]
        XCTAssertTrue(downloadButton.isEnabled)
        downloadButton.click()

        XCTAssertTrue(app.staticTexts["DONE"].firstMatch.waitForExistence(timeout: 20),
                      "queue dock should show the completed download")
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadDir + "/hello.txt"),
                      "downloaded file must exist in the local start dir")

        app.buttons["browser.disconnect"].click()
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
    }

    /// M15.5 end-to-end (screen 7): connect over SFTP to the exec-capable
    /// server (:2223, full OpenSSH — atmoz on :2222 forbids shells), open the
    /// embedded terminal from the toolbar, run `touch` in the real shell, and
    /// see the file appear in the remote pane — proving the whole loop without
    /// scraping terminal text. Built-in terminal is macOS 15+ (ADR-023).
    @MainActor
    func testEmbeddedTerminalTouchShowsFileInRemotePane() throws {
        try XCTSkipUnless(scpServerUp, "SSH/SCP test server not running — testinfra/start.sh")
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("The embedded terminal requires macOS 15+")
        }
        let app = launchIsolatedApp()

        app.buttons["sidebar.newConnection"].click()
        let nameField = app.textFields["editor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click(); nameField.typeText("docker-terminal")

        let hostField = app.textFields["editor.host"]
        hostField.click(); hostField.typeText("127.0.0.1")
        let portField = app.textFields["editor.port"]
        portField.click(); portField.typeKey("a", modifierFlags: .command); portField.typeText("2223")
        let userField = app.textFields["editor.username"]
        userField.click(); userField.typeText("ferry")
        app.buttons["editor.save"].click()

        let connectButton = app.buttons["detail.connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
        connectButton.click()
        let passwordField = app.secureTextFields["passwordPrompt.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        passwordField.click(); passwordField.typeText("ferrypass")
        app.buttons["passwordPrompt.connect"].click()
        trustHostKeyIfPrompted(app)
        XCTAssertTrue(app.staticTexts["browser.status.connected"].waitForExistence(timeout: 20))

        // Open the terminal panel; its dedicated SSH session reuses the trust
        // and credential just resolved — no second prompt (rule 6).
        // The toolbar control is a Toggle (accent-filled while open), which
        // the accessibility tree exposes as a checkbox, not a button.
        let terminalToggle = app.checkBoxes["browser.terminal"].firstMatch
        let terminalControl = terminalToggle.waitForExistence(timeout: 5)
            ? terminalToggle
            : app.descendants(matching: .any)["browser.terminal"].firstMatch
        XCTAssertTrue(terminalControl.waitForExistence(timeout: 5),
                      "the Terminal toolbar control should exist for SSH profiles")
        terminalControl.click()
        let runningState = app.staticTexts["terminal.state.running"].firstMatch
        XCTAssertTrue(runningState.waitForExistence(timeout: 20), "the shell should reach running")

        // Type into the live shell: click inside the terminal area (just below
        // the header's state label — SwiftTerm's NSView takes keys on click).
        func clickTerminalArea() {
            runningState.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: 0, dy: 80))
                .click()
        }
        clickTerminalArea()
        let marker = "ui-term-\(Int.random(in: 10_000...99_999)).txt"
        app.typeText("touch '/home/ferry/\(marker)'\n")

        // The file the shell created appears in the remote pane on refresh.
        app.buttons["browser.refresh"].click()
        var fileRow = app.staticTexts[marker].firstMatch
        if !fileRow.waitForExistence(timeout: 5) {
            app.buttons["browser.refresh"].click()
            fileRow = app.staticTexts[marker].firstMatch
            XCTAssertTrue(fileRow.waitForExistence(timeout: 10),
                          "the file touched in the terminal should list in the remote pane")
        }

        // Clean the server up through the same shell, then close the terminal
        // (✕ confirms while the shell is live) and disconnect.
        clickTerminalArea()
        app.typeText("rm '/home/ferry/\(marker)'\n")
        app.buttons["terminal.close"].click()
        // Confirmation buttons must be queried under windows — a Touch Bar
        // duplicate otherwise trips firstMatch (ADR-015).
        let endSession = app.windows.buttons["End Session"].firstMatch
        if endSession.waitForExistence(timeout: 3) { endSession.click() }

        app.buttons["browser.disconnect"].click()
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
    }
}
