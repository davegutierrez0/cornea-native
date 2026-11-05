import XCTest
@testable import CorneaCore

final class CoreTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; return calendar
    }
    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: hour, minute: minute))!
    }
    func testScheduleTransitionsAcrossMidnightAndInterpolatesFromPreviousProfile() {
        var settings = Settings(); settings.mode = .scheduled; settings.useSleep = true
        settings.dayMinute = 420; settings.nightMinute = 1140; settings.sleepMinute = 1430
        settings.transitionMinutes = 30
        let result = ScheduleEngine.evaluate(settings, at: date(0, 5), calendar: utc)
        XCTAssertEqual(result.values.temperature, 3100, accuracy: 0.001)
        XCTAssertEqual(result.values.brightness, 67.5, accuracy: 0.001)
        let morning = ScheduleEngine.evaluate(settings, at: date(7, 15), calendar: utc)
        XCTAssertEqual(morning.values.temperature, 4350, accuracy: 0.001)
        XCTAssertEqual(ScheduleEngine.evaluate(settings, at: date(12), calendar: utc).values, settings.day)
    }
    func testZeroTransitionSwitchesExactlyAtBoundary() {
        var s = Settings(); s.mode = .scheduled; s.transitionMinutes = 0
        XCTAssertEqual(ScheduleEngine.evaluate(s, at: date(18, 59), calendar: utc).values, s.day)
        XCTAssertEqual(ScheduleEngine.evaluate(s, at: date(19), calendar: utc).values, s.night)
    }
    func testTransitionsAreCappedBeforeNextEvent() {
        var s = Settings(); s.mode = .scheduled; s.useSleep = true; s.transitionMinutes = 120
        s.nightMinute = 19 * 60; s.sleepMinute = 19 * 60 + 30
        let result = ScheduleEngine.evaluate(s, at: date(19, 15), calendar: utc)
        XCTAssertEqual(result.values.temperature, 5250, accuracy: 0.001)
        XCTAssertEqual(ScheduleEngine.evaluate(s, at: date(19, 30), calendar: utc).values, s.night)
    }
    func testRepeatedDSTHourUsesStableLocalSchedule() {
        var c = utc; c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let formatter = ISO8601DateFormatter()
        let first = formatter.date(from: "2026-11-01T08:30:00Z")!
        let second = formatter.date(from: "2026-11-01T09:30:00Z")!
        var s = Settings(); s.mode = .scheduled
        XCTAssertEqual(ScheduleEngine.evaluate(s, at: first, calendar: c).values,
                       ScheduleEngine.evaluate(s, at: second, calendar: c).values)
    }
    func testSunScheduleHandlesPolarSeasonsWithoutNaN() {
        let summer = utc.date(from: DateComponents(year: 2026, month: 6, day: 21))!
        let winter = utc.date(from: DateComponents(year: 2026, month: 12, day: 21))!
        if case .polarDay = SolarTimes.events(date: summer, latitude: 80, longitude: 0, calendar: utc) {} else { XCTFail("Expected polar day") }
        if case .polarNight = SolarTimes.events(date: winter, latitude: 80, longitude: 0, calendar: utc) {} else { XCTFail("Expected polar night") }
        let equinox = utc.date(from: DateComponents(year: 2026, month: 3, day: 20))!
        if case .times(let sunrise, let sunset) = SolarTimes.events(date: equinox, latitude: 0, longitude: 0, calendar: utc) {
            XCTAssertEqual(sunrise, 360, accuracy: 15); XCTAssertEqual(sunset, 1080, accuracy: 15)
        } else { XCTFail("Expected equatorial sunrise and sunset") }
    }
    func testNeutralGainsPreserveCalibrationAndWarmDimmingNeverBrightens() {
        XCTAssertEqual(DisplayValues().gains, [1, 1, 1])
        for temperature in stride(from: 1200.0, through: 6500, by: 100) {
            let gains = DisplayValues(temperature: temperature, brightness: 50).gains
            XCTAssertEqual(gains[0], 0.5)
            XCTAssertTrue(gains.allSatisfy { $0.isFinite && (0...0.5).contains($0) })
            XCTAssertLessThanOrEqual(gains[2], gains[1])
        }
    }
    func testSettingsRejectInvalidImportWithoutSilentClamping() throws {
        var s = Settings(); s.dayMinute = s.nightMinute; XCTAssertThrowsError(try s.validate())
        s = Settings(); s.manual.brightness = 0; XCTAssertThrowsError(try s.validate())
        s = Settings(); s.night.temperature = .nan; XCTAssertThrowsError(try s.validate())
        s = Settings(); s.workMinutes = .infinity; XCTAssertThrowsError(try s.validate())
        s = Settings(); s.schedule = .sun; XCTAssertThrowsError(try s.validate())
        s = Settings(); s.displays["external"] = DisplayPreference(); s.displays["external"]?.values.brightness = 101
        XCTAssertThrowsError(try s.validate())
        s = Settings(); s.manual = Preset.reading.values; s.breaksEnabled = true
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded, s); try decoded.validate()
    }
    func testBreakPausePostponeAndDelayedTickPreserveUserTime() {
        var clock = BreakClock(); clock.start(now: 100, workSeconds: 1200)
        clock.pause(now: 400); XCTAssertEqual(clock.remaining, 900)
        clock.tick(now: 9000, workSeconds: 1200, restSeconds: 20)
        XCTAssertEqual(clock.phase, .paused); XCTAssertEqual(clock.remaining, 900)
        clock.resume(now: 9000)
        clock.tick(now: 9899, workSeconds: 1200, restSeconds: 20)
        XCTAssertEqual(clock.phase, .working); XCTAssertEqual(clock.remaining, 1)
        clock.tick(now: 9901, workSeconds: 1200, restSeconds: 20)
        XCTAssertEqual(clock.phase, .resting); XCTAssertEqual(clock.remaining, 20)
        clock.postpone(now: 9902)
        clock.tick(now: 10202, workSeconds: 1200, restSeconds: 20)
        XCTAssertEqual(clock.phase, .resting)
        clock.tick(now: 20000, workSeconds: 1200, restSeconds: 20)
        XCTAssertEqual(clock.phase, .working); XCTAssertEqual(clock.remaining, 1200)
        clock.stop(); clock.tick(now: 50000, workSeconds: 1200, restSeconds: 20)
        XCTAssertEqual(clock.phase, .stopped)
    }
}
