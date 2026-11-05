import Foundation

public struct DisplayValues: Codable, Equatable, Sendable {
    public var temperature: Double
    public var brightness: Double
    public init(temperature: Double = 6500, brightness: Double = 100) {
        self.temperature = temperature
        self.brightness = brightness
    }
    public var isValid: Bool {
        temperature.isFinite && brightness.isFinite && (1200...6500).contains(temperature) && (20...100).contains(brightness)
    }
    public func blended(to other: Self, fraction: Double) -> Self {
        let t = min(1, max(0, fraction))
        return Self(temperature: temperature + (other.temperature - temperature) * t,
                    brightness: brightness + (other.brightness - brightness) * t)
    }
    // Approximate black-body RGB. Normalize to D65 so 6500 K is exactly neutral.
    // Kelvin describes a target white point, not a calibrated measurement of the panel.
    public var gains: [Float] {
        func rgb(_ kelvin: Double) -> [Double] {
            let t = kelvin / 100
            return [1, min(1, max(0, (99.4708025861 * log(t) - 161.1195681661) / 255)),
                    t <= 19 ? 0 : min(1, max(0, (138.5177312231 * log(t - 10) - 305.0447927307) / 255))]
        }
        let value = rgb(min(6500, max(1200, temperature)))
        let neutral = rgb(6500)
        return zip(value, neutral).map { Float(min(1, $0 / $1) * min(100, max(20, brightness)) / 100) }
    }
}

public enum ControlMode: String, Codable, CaseIterable, Sendable { case manual, scheduled }
public enum ScheduleKind: String, Codable, CaseIterable, Sendable { case clock, sun }
public enum Preset: String, CaseIterable, Identifiable {
    case daylight = "Daylight", evening = "Evening", reading = "Reading", sleep = "Sleep"
    public var id: String { rawValue }
    public var values: DisplayValues {
        switch self {
        case .daylight: return DisplayValues()
        case .evening: return DisplayValues(temperature: 4000, brightness: 85)
        case .reading: return DisplayValues(temperature: 3500, brightness: 75)
        case .sleep: return DisplayValues(temperature: 2200, brightness: 50)
        }
    }
}

public struct DisplayPreference: Codable, Equatable, Sendable {
    public var enabled = true
    public var useOverride = false
    public var values = DisplayValues()
    public init() {}
}

public struct Settings: Codable, Equatable, Sendable {
    public var version = 1
    public var enabled = false
    public var mode = ControlMode.manual
    public var manual = DisplayValues(temperature: 4000, brightness: 85)
    public var day = DisplayValues()
    public var night = DisplayValues(temperature: 4000, brightness: 85)
    public var sleep = DisplayValues(temperature: 2200, brightness: 50)
    public var schedule = ScheduleKind.clock
    public var dayMinute = 7 * 60
    public var nightMinute = 19 * 60
    public var sleepMinute = 23 * 60
    public var useSleep = false
    public var transitionMinutes = 30.0
    public var latitude = 0.0
    public var longitude = 0.0
    public var locationConfigured = false
    public var displays: [String: DisplayPreference] = [:]
    public var breaksEnabled = false
    public var workMinutes = 20.0
    public var restSeconds = 20.0
    public var shortcutsEnabled = true
    public init() {}

    public func validate() throws {
        guard version == 1 else { throw SettingsError.invalid("Unsupported settings version.") }
        guard [manual, day, night, sleep].allSatisfy(\.isValid), displays.values.allSatisfy({ $0.values.isValid }) else {
            throw SettingsError.invalid("Temperature must be 1200–6500 K and brightness must be 20–100%.")
        }
        guard [dayMinute, nightMinute, sleepMinute].allSatisfy({ (0..<1440).contains($0) }),
              dayMinute != nightMinute, !useSleep || (sleepMinute != dayMinute && sleepMinute != nightMinute),
              transitionMinutes.isFinite, (0...120).contains(transitionMinutes) else {
            throw SettingsError.invalid("Schedule times must differ and transitions must be 0–120 minutes.")
        }
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude),
              schedule != .sun || locationConfigured else {
            throw SettingsError.invalid("Enter a valid latitude and longitude for the sun schedule.")
        }
        guard workMinutes.isFinite, restSeconds.isFinite, (1...180).contains(workMinutes), (5...600).contains(restSeconds) else {
            throw SettingsError.invalid("Breaks need 1–180 work minutes and 5–600 rest seconds.")
        }
    }
}
public enum SettingsError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let text): return text } }
}

public struct ScheduleResult: Sendable {
    public let values: DisplayValues
    public let phase: String
}

public enum ScheduleEngine {
    public static func evaluate(_ s: Settings, at date: Date, calendar: Calendar = .current) -> ScheduleResult {
        guard s.mode == .scheduled else { return ScheduleResult(values: s.manual, phase: "Manual") }
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let minute = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
        var day = Double(s.dayMinute), night = Double(s.nightMinute)
        if s.schedule == .sun {
            switch SolarTimes.events(date: date, latitude: s.latitude, longitude: s.longitude, calendar: calendar) {
            case .times(let sunrise, let sunset): day = sunrise; night = sunset
            case .polarDay: return ScheduleResult(values: s.day, phase: "Polar day")
            case .polarNight: return ScheduleResult(values: s.night, phase: "Polar night")
            }
        }
        var events: [(Double, DisplayValues, String)] = [(day, s.day, "Day"), (night, s.night, "Night")]
        if s.useSleep { events.append((Double(s.sleepMinute), s.sleep, "Sleep")) }
        events.sort { $0.0 < $1.0 }
        let current = events.lastIndex(where: { $0.0 <= minute }) ?? events.count - 1
        let previous = (current + events.count - 1) % events.count
        let next = (current + 1) % events.count
        let elapsed = (minute - events[current].0 + 1440).truncatingRemainder(dividingBy: 1440)
        let gap = (events[next].0 - events[current].0 + 1440).truncatingRemainder(dividingBy: 1440)
        let duration = min(s.transitionMinutes, gap)
        let fraction = duration > 0 ? min(1, elapsed / duration) : 1
        return ScheduleResult(values: events[previous].1.blended(to: events[current].1, fraction: fraction),
                              phase: events[current].2 + (fraction < 1 ? " transition" : ""))
    }
}

public enum SolarTimes {
    public enum Events { case times(sunrise: Double, sunset: Double), polarDay, polarNight }
    // NOAA fractional-year solar approximation. Results are local minutes on the selected date.
    public static func events(date: Date, latitude: Double, longitude: Double, calendar: Calendar) -> Events {
        let day = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let angle = 2 * Double.pi / 365 * (day - 1)
        let equation = 229.18 * (0.000075 + 0.001868 * cos(angle) - 0.032077 * sin(angle)
            - 0.014615 * cos(2 * angle) - 0.040849 * sin(2 * angle))
        let declination = 0.006918 - 0.399912 * cos(angle) + 0.070257 * sin(angle)
            - 0.006758 * cos(2 * angle) + 0.000907 * sin(2 * angle)
            - 0.002697 * cos(3 * angle) + 0.00148 * sin(3 * angle)
        let lat = min(89.9999, max(-89.9999, latitude)) * .pi / 180
        let cosine = (cos(90.833 * .pi / 180) / (cos(lat) * cos(declination))) - tan(lat) * tan(declination)
        if cosine < -1 { return .polarDay }
        if cosine > 1 { return .polarNight }
        let hourAngle = acos(cosine) * 180 / .pi
        let offset = Double(calendar.timeZone.secondsFromGMT(for: date)) / 60
        let noon = 720 - 4 * longitude - equation + offset
        func wrap(_ m: Double) -> Double { (m.truncatingRemainder(dividingBy: 1440) + 1440).truncatingRemainder(dividingBy: 1440) }
        return .times(sunrise: wrap(noon - hourAngle * 4), sunset: wrap(noon + hourAngle * 4))
    }
}

public struct BreakClock {
    public enum Phase: Equatable { case stopped, working, resting, paused }
    public private(set) var phase = Phase.stopped
    public private(set) var remaining = 0.0
    private var deadline = 0.0
    private var pausedPhase = Phase.working
    public init() {}
    public mutating func start(now: Double, workSeconds: Double) { phase = .working; deadline = now + workSeconds; remaining = workSeconds }
    public mutating func stop() { phase = .stopped; remaining = 0 }
    public mutating func rest(now: Double, seconds: Double) { phase = .resting; deadline = now + seconds; remaining = seconds }
    public mutating func postpone(now: Double, seconds: Double = 300) { phase = .working; deadline = now + seconds; remaining = seconds }
    public mutating func pause(now: Double) {
        guard phase == .working || phase == .resting else { return }
        remaining = max(0, deadline - now); pausedPhase = phase; phase = .paused
    }
    public mutating func resume(now: Double) {
        guard phase == .paused else { return }
        phase = pausedPhase; deadline = now + remaining
    }
    public mutating func tick(now: Double, workSeconds: Double, restSeconds: Double) {
        guard phase == .working || phase == .resting else { return }
        remaining = max(0, deadline - now)
        if remaining == 0 {
            if phase == .working { rest(now: now, seconds: restSeconds) }
            else { start(now: now, workSeconds: workSeconds) }
        }
    }
}
