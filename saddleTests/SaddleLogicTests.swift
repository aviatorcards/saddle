import XCTest
@testable import saddle

final class RemotePathTests: XCTestCase {
    func testJoinAndName() {
        XCTAssertEqual(RemotePath.join("/home/me", "notes"), "/home/me/notes")
        XCTAssertEqual(RemotePath.join("/", "notes"), "/notes")
        XCTAssertEqual(RemotePath.parent(of: "/home/me/notes"), "/home/me")
        XCTAssertEqual(RemotePath.name(of: "/home/me/notes"), "notes")
    }

    func testResolvedStaysInsideTheMount() {
        XCTAssertEqual(RemotePath.resolved("a/b", under: "/home/me"), "/home/me/a/b")
        XCTAssertEqual(RemotePath.resolved("a/../b", under: "/home/me"), "/home/me/b")
        XCTAssertEqual(RemotePath.resolved("", under: "/home/me"), "/home/me")
        XCTAssertEqual(RemotePath.resolved("", under: "/"), "/")
        XCTAssertNil(RemotePath.resolved("../etc", under: "/home/me"))
        XCTAssertNil(RemotePath.resolved("a/../../b", under: "/home/me"))
        XCTAssertNil(RemotePath.resolved("a/\0b", under: "/home/me"))
    }

    func testUnsafeComponentsAndPartialUploads() {
        XCTAssertFalse(RemotePath.isSafeComponent("."))
        XCTAssertFalse(RemotePath.isSafeComponent(".."))
        XCTAssertFalse(RemotePath.isSafeComponent("a/b"))
        XCTAssertFalse(RemotePath.isSafeComponent(""))
        XCTAssertTrue(RemotePath.isSafeComponent(".bashrc"))
        XCTAssertTrue(RemotePath.isPartialUpload(".saddle-abc.part"))
        XCTAssertFalse(RemotePath.isPartialUpload(".saddle-abc.bak"))
        XCTAssertFalse(RemotePath.isPartialUpload("notes.txt"))
    }

    func testBackupNamesRecordTheOriginal() {
        let backup = RemotePath.backupName(for: "report.final.pdf")
        XCTAssertTrue(backup.hasPrefix(".saddle-"))
        XCTAssertTrue(backup.hasSuffix(".bak"))
        XCTAssertEqual(RemotePath.originalName(ofBackup: backup), "report.final.pdf")
        // Too long to embed the original: falls back to an anonymous backup, which stays visible.
        let long = RemotePath.backupName(for: String(repeating: "a", count: 250))
        XCTAssertNil(RemotePath.originalName(ofBackup: long))
        XCTAssertNil(RemotePath.originalName(ofBackup: ".saddle-abc.part"))
        XCTAssertNil(RemotePath.originalName(ofBackup: "notes.bak"))
    }

    func testIsInsideRequiresAComponentBoundary() {
        XCTAssertTrue(RemotePath.isInside("/home/me", root: "/home/me"))
        XCTAssertTrue(RemotePath.isInside("/home/me/www", root: "/home/me"))
        XCTAssertFalse(RemotePath.isInside("/home/meadow", root: "/home/me"))
        XCTAssertFalse(RemotePath.isInside("/var/www", root: "/home/me"))
        XCTAssertTrue(RemotePath.isInside("/var/www", root: "/"))
    }
}

final class IdentifierMapTests: XCTestCase {
    func testRelocatingMovesDescendantsAndLeavesSimilarNames() {
        let original = [
            "1": "docs",
            "2": "docs/readme",
            "3": "docs-old",
        ]
        let moved = IdentifierMap.relocating(original, from: "docs", to: "archive")
        XCTAssertEqual(moved["1"], "archive")
        XCTAssertEqual(moved["2"], "archive/readme")
        XCTAssertEqual(moved["3"], "docs-old")
        XCTAssertEqual(IdentifierMap.index(pathByID: moved)["archive/readme"], "2")
    }
}

final class SSHConfigImporterTests: XCTestCase {
    func testFirstValueWinsAndWildcardsAreNotImported() throws {
        let text = """
        User alice
        Host web *.example.com other
            HostName web.example.com
            User bob
            Port 2222
            IdentityFile ~/.ssh/id_ed25519
        Host *
            User carol
        """
        let profiles = SSHConfigImporter.profiles(fromConfig: text)
        let names = profiles.map(\.name)
        XCTAssertEqual(names, ["web", "other"])
        let web = try XCTUnwrap(profiles.first { $0.name == "web" })
        XCTAssertEqual(web.host, "web.example.com")
        // The keyword before any Host is obtained first, which is what OpenSSH does.
        XCTAssertEqual(web.username, "alice")
        XCTAssertEqual(web.port, 2222)
        XCTAssertEqual(web.authMethod, .privateKey)
        XCTAssertEqual(web.privateKeyName, "id_ed25519")
    }

    func testHostBlockBeatsALaterDefault() {
        let text = """
        Host web
            User bob
            HostName web.example.com
        Host *
            User alice
        """
        let profiles = SSHConfigImporter.profiles(fromConfig: text)
        XCTAssertEqual(profiles.map(\.name), ["web"])
        XCTAssertEqual(profiles.first?.username, "bob")
        XCTAssertEqual(profiles.first?.host, "web.example.com")
    }

    func testMatchBlocksAndPatternsAreSkipped() {
        let text = """
        Match host *.internal
            User mallory
        Host web
            HostName web.example.com
        Host *
        """
        let profiles = SSHConfigImporter.profiles(fromConfig: text)
        XCTAssertEqual(profiles.map(\.name), ["web"])
        XCTAssertNotEqual(profiles.first?.username, "mallory")
    }

    func testContinuationLinesAndCommaSeparatedHosts() {
        let text = """
        Host one,two
            HostName \\
            shared.example.com
        """
        let profiles = SSHConfigImporter.profiles(fromConfig: text)
        XCTAssertEqual(Set(profiles.map(\.name)), ["one", "two"])
        XCTAssertTrue(profiles.allSatisfy { $0.host == "shared.example.com" })
    }

    func testGlob() {
        XCTAssertTrue(SSHConfigImporter.glob("*.example.com", "a.example.com"))
        XCTAssertFalse(SSHConfigImporter.glob("*.example.com", "example.com"))
        XCTAssertTrue(SSHConfigImporter.glob("web?", "web1"))
        XCTAssertFalse(SSHConfigImporter.glob("web?", "web12"))
    }
}

final class KnownHostsTests: XCTestCase {
    func testFingerprintMatchesOpenSSHStyle() {
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl comment"
        XCTAssertEqual(
            KnownHosts.normalized(key),
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl")
        XCTAssertEqual(
            KnownHosts.fingerprint(ofOpenSSHKey: key),
            "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU")
        XCTAssertEqual(KnownHosts.fingerprint(ofOpenSSHKey: "not a key"), "unknown")
    }

    func testHostKeyLookupKey() {
        XCTAssertEqual(KnownHosts.key(host: "Example.COM", port: 22), "example.com")
        XCTAssertEqual(KnownHosts.key(host: "Example.COM", port: 2222), "[example.com]:2222")
    }

    func testParseKey() {
        let (host1, port1) = KnownHosts.parseKey("example.com")
        XCTAssertEqual(host1, "example.com")
        XCTAssertEqual(port1, 22)

        let (host2, port2) = KnownHosts.parseKey("[example.com]:2222")
        XCTAssertEqual(host2, "example.com")
        XCTAssertEqual(port2, 2222)

        let (host3, port3) = KnownHosts.parseKey("[2001:db8::1]:2222")
        XCTAssertEqual(host3, "2001:db8::1")
        XCTAssertEqual(port3, 2222)
    }
}

final class AppSettingsTests: XCTestCase {
    func testDefaultValues() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(userDefaults: defaults)
        XCTAssertTrue(settings.openInFinderOnMount)
        XCTAssertTrue(settings.notifyOnConnectionError)
        XCTAssertFalse(settings.notifyOnMount)
        XCTAssertFalse(settings.notifyOnDisconnect)
        XCTAssertEqual(settings.defaultParallelTransfers, 3)
        XCTAssertEqual(settings.defaultRefreshInterval, 60.0)
        XCTAssertTrue(settings.defaultShowHiddenFiles)
        XCTAssertEqual(settings.defaultPort, 22)
    }

    func testMutatingSettingsPersists() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(userDefaults: defaults)
        settings.openInFinderOnMount = false
        settings.defaultParallelTransfers = 6
        settings.defaultRefreshInterval = 300
        settings.defaultShowHiddenFiles = false
        settings.defaultPort = 2222

        let reloaded = AppSettings(userDefaults: defaults)
        XCTAssertFalse(reloaded.openInFinderOnMount)
        XCTAssertEqual(reloaded.defaultParallelTransfers, 6)
        XCTAssertEqual(reloaded.defaultRefreshInterval, 300)
        XCTAssertFalse(reloaded.defaultShowHiddenFiles)
        XCTAssertEqual(reloaded.defaultPort, 2222)
    }

    func testResetToDefaults() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(userDefaults: defaults)
        settings.defaultParallelTransfers = 8
        settings.resetToDefaults()

        XCTAssertEqual(settings.defaultParallelTransfers, 3)
    }
}

final class SFTPSessionTests: XCTestCase {
    func testConnectionErrorsDoNotIncludeLocalIOOrCancellation() {
        XCTAssertFalse(SFTPSession.isConnectionError(CancellationError()))
        XCTAssertFalse(SFTPSession.isConnectionError(CocoaError(.fileWriteOutOfSpace)))
        XCTAssertFalse(SFTPSession.isConnectionError(SaddleError.authenticationFailed))
        XCTAssertFalse(SFTPSession.isConnectionError(SaddleError.outsideMount))
        XCTAssertTrue(SFTPSession.isConnectionError(POSIXError(.ECONNRESET)))
        XCTAssertFalse(SFTPSession.isConnectionError(POSIXError(.ENOENT)))
    }

    func testPublicDescriptionRedactsSecrets() {
        struct Box: Error, CustomStringConvertible {
            var description: String
        }
        XCTAssertEqual(
            SFTPSession.publicDescription(of: Box(description: "password=hunter2")),
            "the secure connection could not be established")
        XCTAssertFalse(SFTPSession.publicDescription(of: Box(description: "connection reset by peer")).contains("\n"))
    }
}
