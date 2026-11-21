import XCTest
@testable import Buddy

final class AppGroupAndSnapshotTests: XCTestCase {
    func testExtractAppGroupsFromCMSWrappedMobileProvision() {
        let plistXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>AppIDName</key>
            <string>Buddy SideStore</string>
            <key>TeamIdentifier</key>
            <array>
                <string>ABC123XYZ9</string>
            </array>
            <key>Entitlements</key>
            <dict>
                <key>application-identifier</key>
                <string>ABC123XYZ9.com.yuvaraja.buddy.ABC123XYZ9</string>
                <key>com.apple.security.application-groups</key>
                <array>
                    <string>group.com.yuvaraja.buddy.ABC123XYZ9</string>
                </array>
            </dict>
        </dict>
        </plist>
        """

        // Simulate realistic PKCS#7 / CMS DER binary wrapper before and after XML plist payload.
        let cmsHeader = Data([0x30, 0x82, 0x05, 0x1A, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02, 0xA0])
        let cmsTrailer = Data([0x31, 0x82, 0x01, 0x22, 0x02, 0x01, 0x01, 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF])

        var provisionBytes = Data()
        provisionBytes.append(cmsHeader)
        provisionBytes.append(Data(plistXML.utf8))
        provisionBytes.append(cmsTrailer)

        let extracted = AppGroupResolver.extractAppGroups(fromMobileProvisionData: provisionBytes)
        XCTAssertEqual(extracted, ["group.com.yuvaraja.buddy.ABC123XYZ9"])
    }

    func testExtractAppGroupsHandlesInvalidProvisionDataGracefully() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0xFF])
        XCTAssertEqual(AppGroupResolver.extractAppGroups(fromMobileProvisionData: garbage), [])

        let plistWithoutGroups = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Entitlements</key><dict></dict></dict></plist>
        """.utf8)
        XCTAssertEqual(AppGroupResolver.extractAppGroups(fromMobileProvisionData: plistWithoutGroups), [])
    }

    func testWidgetSnapshotSaveAndLoadRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("widget_snapshot.json")
        let fixedNow = Date(timeIntervalSince1970: 1_740_000_000)
        let startedAt = Date(timeIntervalSince1970: 1_739_998_500)

        let expected = WidgetSnapshot(
            updatedAt: fixedNow,
            preferredUnit: .lbs,
            activeSession: ActiveSessionSnapshot(
                sessionID: "session-42",
                title: "Lower Body",
                startedAt: startedAt,
                totalSets: 6,
                totalReps: 78,
                totalVolumeKg: 2850.5,
                exerciseCount: 2,
                lastExerciseName: "Leg Extension",
                lastSetSummary: "3 × 15 · 100 lbs"
            ),
            todaySets: 6,
            todayReps: 78,
            todayVolumeKg: 2850.5,
            todayExercises: [
                ExerciseSummarySnapshot(id: "ex-1", name: "Leg Extension", setCount: 3, summary: "3 × 15 · 100 lbs"),
                ExerciseSummarySnapshot(id: "ex-2", name: "Romanian Deadlift", setCount: 3, summary: "3 × 11 · 155 lbs")
            ],
            currentStreakDays: 5,
            workoutsThisWeek: 3,
            weeklyGoal: 4,
            weeklyDays: [
                DayActivitySnapshot(
                    id: "day-0",
                    weekdayLabel: "M",
                    date: Date(timeIntervalSince1970: 1_739_923_200),
                    setCount: 12,
                    volumeKg: 4100,
                    isToday: false
                ),
                DayActivitySnapshot(
                    id: "day-1",
                    weekdayLabel: "T",
                    date: Date(timeIntervalSince1970: 1_740_009_600),
                    setCount: 6,
                    volumeKg: 2850.5,
                    isToday: true
                )
            ]
        )

        WidgetSnapshot.save(expected, to: fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let loaded = WidgetSnapshot.load(from: fileURL)
        XCTAssertEqual(loaded, expected)
    }

    func testWidgetSnapshotLoadMissingFileReturnsEmptyFallback() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).json")
        let snapshot = WidgetSnapshot.load(from: missingURL)

        XCTAssertNil(snapshot.activeSession)
        XCTAssertEqual(snapshot.todaySets, 0)
        XCTAssertEqual(snapshot.todayVolumeKg, 0)
        XCTAssertEqual(snapshot.weeklyDays.count, 7)
    }

    func testDeepLinkParsing() {
        XCTAssertEqual(DeepLink(url: URL(string: "buddy://record")!), .record)
        XCTAssertEqual(DeepLink(url: URL(string: "buddy://session")!), .session)
        XCTAssertEqual(DeepLink(url: URL(string: "buddy://trends")!), .trends)
        XCTAssertEqual(DeepLink(url: URL(string: "buddy://coach")!), .coach)
        XCTAssertEqual(DeepLink(url: URL(string: "BUDDY://RECORD")!), .record)

        XCTAssertEqual(DeepLink(url: DeepLink.record.url), .record)
        XCTAssertEqual(DeepLink(url: DeepLink.trends.url), .trends)
        XCTAssertEqual(DeepLink(url: DeepLink.coach.url), .coach)

        XCTAssertNil(DeepLink(url: URL(string: "https://record")!))
        XCTAssertNil(DeepLink(url: URL(string: "other://trends")!))
        XCTAssertNil(DeepLink(url: URL(string: "buddy://unknown")!))
    }

    func testWeightUnitConversionAndFormatting() {
        XCTAssertEqual(WeightUnit.kg.toKg(60), 60, accuracy: 0.0001)
        XCTAssertEqual(WeightUnit.kg.fromKg(60), 60, accuracy: 0.0001)

        let fiftyLbsInKg = WeightUnit.lbs.toKg(50)
        XCTAssertEqual(fiftyLbsInKg, 22.6796, accuracy: 0.001)
        XCTAssertEqual(WeightUnit.lbs.fromKg(fiftyLbsInKg), 50, accuracy: 0.001)
        XCTAssertEqual(WeightUnit.lbs.fromKg(100), 220.462, accuracy: 0.01)

        XCTAssertEqual(WeightUnit.kg.formatWeight(kg: 60), "60 kg")
        XCTAssertEqual(WeightUnit.kg.formatWeight(kg: 62.5), "62.5 kg")
        XCTAssertEqual(WeightUnit.lbs.formatWeight(kg: fiftyLbsInKg), "50 lbs")

        XCTAssertEqual(WeightUnit.kg.formatVolume(kg: 450), "450 kg")
        XCTAssertEqual(WeightUnit.kg.formatVolume(kg: 12_500), "12.5k kg")

        XCTAssertEqual(DurationFormatter.formatClock(seconds: 90), "01:30")
        XCTAssertEqual(DurationFormatter.formatClock(seconds: 3_665), "1:01:05")
        XCTAssertEqual(DurationFormatter.formatCompact(seconds: 90), "1m 30s")
        XCTAssertEqual(DurationFormatter.formatCompact(seconds: 1_200), "20m")
    }
}
