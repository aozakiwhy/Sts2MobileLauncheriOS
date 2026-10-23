import Foundation
import XCTest
import CryptoKit
@testable import LauncherCore

final class PayloadLibraryTests: XCTestCase {
    private var temporary: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: temporary) }

    // Synthetic signatures only: no game code or assets are included in tests.
    private func fixture(_ name: String, version: String) throws -> URL {
        let source = temporary.appendingPathComponent(name)
        let data = source.appendingPathComponent("data_sts2_windows_x86_64")
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("GDPC-fixture".utf8).write(to: source.appendingPathComponent("SlayTheSpire2.pck"))
        try JSONSerialization.data(withJSONObject: ["version": version])
            .write(to: source.appendingPathComponent("release_info.json"))
        try Data("MZ-fixture".utf8).write(to: data.appendingPathComponent("sts2.dll"))
        for name in ["sts2.deps.json", "sts2.runtimeconfig.json"] {
            try Data("{}".utf8).write(to: data.appendingPathComponent(name))
        }
        return source
    }

    func testImportSwitchRestartAndIsolatedSaveRoots() async throws {
        let root = temporary.appendingPathComponent("library")
        let library = try PayloadLibrary(root: root)
        _ = try await library.importDirectory(fixture("a", version: "v-test-a"))
        _ = try await library.importDirectory(fixture("b", version: "v-test-b"))
        let state = await library.snapshot()
        XCTAssertEqual(state.payloads.count, 2)
        let first = state.profiles[0]
        let second = state.profiles[1]
        let firstRoot = try await library.accountRoot(for: first.id)
        let secondRoot = try await library.accountRoot(for: second.id)
        XCTAssertNotEqual(firstRoot, secondRoot)
        try Data("save a".utf8).write(to: firstRoot.appendingPathComponent("profile.save"))
        try await library.select(first.id)
        let restarted = try PayloadLibrary(root: root)
        let restored = await restarted.snapshot()
        XCTAssertEqual(restored.selectedProfileID, first.id)
        XCTAssertEqual(try Data(contentsOf: firstRoot.appendingPathComponent("profile.save")), Data("save a".utf8))
        XCTAssertFalse(fm.fileExists(atPath: secondRoot.appendingPathComponent("profile.save").path))
        XCTAssertEqual(restored.payloads[0].dllSHA256.count, 64)
    }

    func testInvalidPayloadDoesNotChangeInstalledSelection() async throws {
        let library = try PayloadLibrary(root: temporary.appendingPathComponent("library"))
        _ = try await library.importDirectory(fixture("good", version: "good"))
        let before = await library.snapshot()
        let bad = try fixture("bad", version: "bad")
        try Data("oops".utf8).write(to: bad.appendingPathComponent("SlayTheSpire2.pck"))
        do {
            _ = try await library.importDirectory(bad)
            XCTFail("Invalid PCK accepted")
        } catch LauncherError.invalidPayload { }
        let after = await library.snapshot()
        XCTAssertEqual(before, after)
    }

    func testSymbolicLinkRejectedWithoutReadingTarget() async throws {
        let library = try PayloadLibrary(root: temporary.appendingPathComponent("library"))
        let source = try fixture("source", version: "test")
        let secret = temporary.appendingPathComponent("private.txt")
        try Data("do not copy".utf8).write(to: secret)
        try fm.createSymbolicLink(at: source.appendingPathComponent("linked"), withDestinationURL: secret)
        do {
            _ = try await library.importDirectory(source)
            XCTFail("Symlink accepted")
        } catch LauncherError.unsafeFile { }
        let state = await library.snapshot()
        XCTAssertTrue(state.payloads.isEmpty)
    }

    func testMissingRequiredFileRejected() async throws {
        let library = try PayloadLibrary(root: temporary.appendingPathComponent("library"))
        let source = try fixture("source", version: "test")
        try fm.removeItem(at: source.appendingPathComponent("data_sts2_windows_x86_64/sts2.deps.json"))
        do {
            _ = try await library.importDirectory(source)
            XCTFail("Incomplete payload accepted")
        } catch LauncherError.invalidPayload { }
    }

    func testCorruptIndexNeverSilentlyResetsLibrary() throws {
        let root = temporary.appendingPathComponent("library")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let index = root.appendingPathComponent("library.json")
        let bad = Data("{broken".utf8)
        try bad.write(to: index)
        XCTAssertThrowsError(try PayloadLibrary(root: root))
        XCTAssertEqual(try Data(contentsOf: index), bad)
    }

    func testIndexWriteFailureRollsBackNewInstallation() async throws {
        let root = temporary.appendingPathComponent("library")
        let library = try PayloadLibrary(root: root)
        _ = try await library.importDirectory(fixture("good", version: "good"))
        let before = await library.snapshot()
        // Force atomic index replacement to fail after the staged payload is moved.
        try fm.removeItem(at: root.appendingPathComponent("library.json"))
        try fm.createDirectory(at: root.appendingPathComponent("library.json"), withIntermediateDirectories: false)
        do {
            _ = try await library.importDirectory(fixture("second", version: "second"))
            XCTFail("Index failure ignored")
        } catch { }
        let after = await library.snapshot()
        XCTAssertEqual(before, after)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("payloads").path).count, 1)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("instances").path).count, 1)
    }

    func testCancelledImportDoesNotPublishPayload() async throws {
        let library = try PayloadLibrary(root: temporary.appendingPathComponent("library"))
        let source = try fixture("source", version: "test")
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.cancelAll()
                group.addTask { _ = try await library.importDirectory(source) }
                try await group.waitForAll()
            }
            XCTFail("Cancellation ignored")
        } catch is CancellationError { }
        let state = await library.snapshot()
        XCTAssertTrue(state.payloads.isEmpty)
    }

    func testOverlappingInputIsRejected() async throws {
        let library = try PayloadLibrary(root: temporary.appendingPathComponent("library"))
        do {
            _ = try await library.importDirectory(temporary)
            XCTFail("Recursive import accepted")
        } catch LauncherError.unsafeFile { }
    }

    func testManifestIdentityPreservesUnsigned64Bit() {
        XCTAssertEqual(SteamManifestID("18446744073709551615")?.value, UInt64.max)
        for invalid in ["", "0", "-1", "+1", "1.2", "1e9", " 1", "１２", "18446744073709551616"] {
            XCTAssertNil(SteamManifestID(invalid))
        }
    }

    func testRuntimeCannotReportFalseLaunchSuccess() {
        XCTAssertThrowsError(try GameRuntime.launch())
    }

    func testStreamingDigestsMatchOriginalAcrossChunkBoundaries() async throws {
        let source = try fixture("large", version: "test")
        var pck = Data("GDPC".utf8)
        pck.append(Data(repeating: 0x5a, count: 3 * 1024 * 1024 + 137))
        try pck.write(to: source.appendingPathComponent("SlayTheSpire2.pck"))
        let library = try PayloadLibrary(root: temporary.appendingPathComponent("library"))
        let payload = try await library.importDirectory(source)
        let expectedPCK = SHA256.hash(data: pck).map { String(format: "%02x", $0) }.joined()
        let expectedDLL = SHA256.hash(data: Data("MZ-fixture".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(payload.pckSHA256, expectedPCK)
        XCTAssertEqual(payload.dllSHA256, expectedDLL)
        let stored = temporary.appendingPathComponent("library/payloads/\(payload.id.uuidString)/game/SlayTheSpire2.pck")
        XCTAssertEqual(try Data(contentsOf: stored), pck)
    }

    func testHotDeviceRejectsBeforeCopyAndCanRetryAfterCooling() async throws {
        let readings = TestConditions()
        readings.stop(after: 1)
        let root = temporary.appendingPathComponent("library")
        let library = try PayloadLibrary(root: root, conditions: { readings.read() })
        let source = try fixture("source", version: "test")
        do {
            _ = try await library.importDirectory(source)
            XCTFail("Hot import accepted")
        } catch LauncherError.thermalLimited { }
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("staging").path))
        readings.stop(after: nil)
        _ = try await library.importDirectory(source)
        let state = await library.snapshot()
        XCTAssertEqual(state.payloads.count, 1)
    }

    func testHeatDuringCopyRollsBackWithoutChangingPreviousVersion() async throws {
        let readings = TestConditions()
        let root = temporary.appendingPathComponent("library")
        let library = try PayloadLibrary(root: root, conditions: { readings.read() })
        _ = try await library.importDirectory(fixture("good", version: "good"))
        let before = await library.snapshot()
        let source = try fixture("large", version: "large")
        var pck = Data("GDPC".utf8)
        pck.append(Data(repeating: 0x5a, count: 9 * 1024 * 1024))
        try pck.write(to: source.appendingPathComponent("SlayTheSpire2.pck"))
        // First reading permits import; the 8 MiB checkpoint reports serious heat.
        readings.stop(after: 2)
        do {
            _ = try await library.importDirectory(source)
            XCTFail("Import continued after thermal limit")
        } catch LauncherError.thermalLimited { }
        let after = await library.snapshot()
        XCTAssertEqual(before, after)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("payloads").path).count, 1)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path).isEmpty)
    }

    func testSelectingCurrentProfileDoesNotRewriteIndex() async throws {
        let root = temporary.appendingPathComponent("library")
        let library = try PayloadLibrary(root: root)
        _ = try await library.importDirectory(fixture("source", version: "test"))
        let state = await library.snapshot()
        let index = root.appendingPathComponent("library.json")
        let marker = Date(timeIntervalSince1970: 100)
        try fm.setAttributes([.modificationDate: marker], ofItemAtPath: index.path)
        try await library.select(XCTUnwrap(state.selectedProfileID))
        let attributes = try fm.attributesOfItem(atPath: index.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, marker)
    }
}

/// Thread-safe synthetic thermal readings; never changes the host's power state.
private final class TestConditions: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var stopAt: Int?
    func stop(after count: Int?) {
        lock.lock()
        defer { lock.unlock() }
        calls = 0
        stopAt = count
    }
    func read() -> ImportConditions {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return ImportConditions(heat: stopAt.map({ calls >= $0 }) == true ? .hot : .normal)
    }
}
