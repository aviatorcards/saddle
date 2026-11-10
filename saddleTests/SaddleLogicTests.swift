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

final class DirectoryPageTests: XCTestCase {
    func testInitialTokenStartsAtZero() {
        XCTAssertEqual(DirectoryPage.offset(from: nil), 0)
        XCTAssertEqual(DirectoryPage.offset(from: Data()), 0)
        XCTAssertEqual(DirectoryPage.offset(from: Data([0, 1, 2, 3, 4])), 0)
    }

    func testPageTokensRoundTripAndStopOnTheLastPartialPage() {
        let count = 250
        let pageSize = 100
        var offset = 0
        var seen = 0
        var pages = 0
        while true {
            let bounds = DirectoryPage.bounds(itemCount: count, offset: offset, pageSize: pageSize)
            seen += bounds.end - bounds.start
            pages += 1
            guard let next = bounds.nextOffset else { break }
            let token = DirectoryPage.token(forOffset: next)
            XCTAssertEqual(DirectoryPage.offset(from: token), next)
            offset = next
        }
        XCTAssertEqual(pages, 3)
        XCTAssertEqual(seen, count)
        XCTAssertEqual(offset, 200)
    }

    func testLargeDirectoryPagesDoNotOverlapOrDropItems() {
        let count = 10_000
        let pageSize = DirectoryPage.fallbackSize
        var offset = 0
        var covered = Array(repeating: false, count: count)
        var pageCount = 0
        while true {
            let bounds = DirectoryPage.bounds(itemCount: count, offset: offset, pageSize: pageSize)
            XCTAssertLessThanOrEqual(bounds.end - bounds.start, pageSize)
            for index in bounds.start..<bounds.end {
                XCTAssertFalse(covered[index])
                covered[index] = true
            }
            pageCount += 1
            guard let next = bounds.nextOffset else {
                XCTAssertEqual(bounds.end, count)
                break
            }
            offset = DirectoryPage.offset(from: DirectoryPage.token(forOffset: next))
        }
        XCTAssertEqual(pageCount, 100)
        XCTAssertTrue(covered.allSatisfy { $0 })
    }

    func testSuggestedPageSizeIsCapped() {
        XCTAssertEqual(DirectoryPage.size(suggested: nil), 100)
        XCTAssertEqual(DirectoryPage.size(suggested: 0), 1)
        XCTAssertEqual(DirectoryPage.size(suggested: 40), 40)
        XCTAssertEqual(DirectoryPage.size(suggested: 5_000), DirectoryPage.maximumSize)
    }
}

final class DownloadPinsTests: XCTestCase {
    func testPinAndReleaseSurviveARoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "pins-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var pins = DownloadPins()
        pins.pin("docs")
        pins.pin("docs/archive")
        pins.release("docs/archive/old")
        try pins.save(to: url)
        let loaded = DownloadPins.load(from: url)
        XCTAssertTrue(loaded.keeps("docs/notes.txt", keepAll: false))
        XCTAssertTrue(loaded.keeps("docs/archive/report.pdf", keepAll: false))
        XCTAssertFalse(loaded.keeps("docs/archive/old", keepAll: false))
        XCTAssertFalse(loaded.keeps("docs/archive/old/page.txt", keepAll: true))
        XCTAssertFalse(loaded.keeps("other.txt", keepAll: false))
        XCTAssertTrue(loaded.keeps("other.txt", keepAll: true))
    }

    func testPinningAFolderClearsReleasesInsideIt() {
        var pins = DownloadPins()
        pins.release("photos/trip")
        pins.pin("photos")
        XCTAssertTrue(pins.keeps("photos/trip/img.jpg", keepAll: false))
        XCTAssertFalse(pins.released.contains("photos/trip"))
    }

    func testReleasingTheRootTurnsKeepAllOffForEverything() {
        var pins = DownloadPins()
        pins.release("")
        XCTAssertFalse(pins.keeps("", keepAll: true))
        XCTAssertFalse(pins.keeps("a/b", keepAll: true))
        pins.pin("a")
        XCTAssertTrue(pins.keeps("a/b", keepAll: true))
    }
}

final class PrefetchPlannerTests: XCTestCase {
    private let limits = PrefetchPlanner.Limits(enabled: true, maxFileBytes: 5 * 1024 * 1024, maxFolderBytes: 50 * 1024 * 1024)

    func testCapsAndExclusions() {
        let mb = UInt64(1024 * 1024)
        let files = [
            PrefetchCandidate(name: "small.txt", size: mb),
            PrefetchCandidate(name: "huge.bin", size: 6 * mb),
            PrefetchCandidate(name: ".secret", size: mb, isHidden: true),
            PrefetchCandidate(name: ".saddle-1.part", size: mb, isPartial: true),
            PrefetchCandidate(name: "outside", size: mb, isSymlink: true, symlinkEscapesMount: true),
            PrefetchCandidate(name: "inside-link", size: 2 * mb, isSymlink: true, symlinkEscapesMount: false),
            PrefetchCandidate(name: "folder", size: 0, isDirectory: true),
            PrefetchCandidate(name: "also-small.txt", size: 2 * mb),
        ]
        let chosen = PrefetchPlanner.select(files, limits: limits)
        XCTAssertEqual(chosen.map(\.name), ["small.txt", "inside-link", "also-small.txt"])
    }

    func testFolderCapSkipsAFileThatDoesNotFitAndKeepsALaterSmallerOne() {
        let mb = UInt64(1024 * 1024)
        let limits = PrefetchPlanner.Limits(enabled: true, maxFileBytes: 10 * mb, maxFolderBytes: 5 * mb)
        let files = [
            PrefetchCandidate(name: "a", size: 3 * mb),
            PrefetchCandidate(name: "b", size: 3 * mb),
            PrefetchCandidate(name: "c", size: 2 * mb),
        ]
        XCTAssertEqual(PrefetchPlanner.select(files, limits: limits).map(\.name), ["a", "c"])
    }

    func testDisabledPrefetchSelectsNothing() {
        var limits = limits
        limits.enabled = false
        XCTAssertTrue(PrefetchPlanner.select([PrefetchCandidate(name: "a", size: 10)], limits: limits).isEmpty)
    }
}

final class ListingAndProfileTests: XCTestCase {
    func testCompleteAttributesDoNotNeedAnotherStat() {
        XCTAssertFalse(RemoteListing.needsExtraRequest(hasSize: true, hasModified: true, hasPermissions: true, isSymlink: false))
        XCTAssertTrue(RemoteListing.needsExtraRequest(hasSize: true, hasModified: false, hasPermissions: true, isSymlink: false))
        XCTAssertTrue(RemoteListing.needsExtraRequest(hasSize: true, hasModified: true, hasPermissions: true, isSymlink: true))
    }

    func testMetadataCacheExpiresAndDropsAPrefix() {
        var cache = MetadataCache<String>(ttl: 30)
        let now = Date()
        cache.insert("notes", for: "/home/me/notes", at: now)
        cache.insert("other", for: "/home/meadow", at: now)
        XCTAssertEqual(cache.lookup("/home/me/notes", at: now.addingTimeInterval(10)), "notes")
        XCTAssertNil(cache.lookup("/home/me/notes", at: now.addingTimeInterval(31)))
        cache.insert("notes", for: "/home/me/notes", at: now)
        cache.insert("child", for: "/home/me/notes/a", at: now)
        cache.remove(prefix: "/home/me/notes")
        XCTAssertNil(cache.lookup("/home/me/notes", at: now))
        XCTAssertNil(cache.lookup("/home/me/notes/a", at: now))
        XCTAssertEqual(cache.lookup("/home/meadow", at: now), "other")
    }

    func testSavedProfileWithoutKeepAllStillLoads() throws {
        let id = UUID()
        let json = """
        {"authMethod":"password","host":"example.com","id":"\(id.uuidString)","maxConnections":3,"name":"Example","port":22,"refreshInterval":60,"remotePath":"","showHiddenFiles":true,"username":"ada"}
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: json)
        XCTAssertFalse(profile.keepAllDownloaded)
        XCTAssertEqual(profile.host, "example.com")
        let data = try JSONEncoder().encode(profile)
        let again = try JSONDecoder().decode(ConnectionProfile.self, from: data)
        XCTAssertEqual(again, profile)
    }
}
