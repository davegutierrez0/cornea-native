import AppKit
import CoreGraphics
import CorneaCore

struct GammaSnapshot: Codable {
    let uuid: String
    let red: [Float]
    let green: [Float]
    let blue: [Float]
}

func displayUUID(_ id: CGDirectDisplayID) -> String? {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
    return CFUUIDCreateString(nil, uuid) as String
}

func onlineDisplays() throws -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success else { throw DisplayError.failed("Cannot enumerate displays.") }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { throw DisplayError.failed("Display enumeration changed. Try Refresh displays.") }
    return Array(ids.prefix(Int(count)))
}

func readGamma(_ id: CGDirectDisplayID) throws -> GammaSnapshot {
    let capacity = CGDisplayGammaTableCapacity(id)
    guard capacity > 1, capacity <= 65536, let uuid = displayUUID(id) else {
        throw DisplayError.failed("This display does not expose a supported gamma table.")
    }
    var r = [Float](repeating: 0, count: Int(capacity)), g = r, b = r
    var count: UInt32 = 0
    let result = CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &count)
    guard result == .success, count > 1, count <= capacity,
          [r, g, b].allSatisfy({ $0.prefix(Int(count)).allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } }),
          [r, g, b].allSatisfy({ $0[Int(count) - 1] > 0 }) else {
        throw DisplayError.failed("Cannot read display calibration (Core Graphics \(result.rawValue)).")
    }
    return GammaSnapshot(uuid: uuid, red: Array(r.prefix(Int(count))), green: Array(g.prefix(Int(count))), blue: Array(b.prefix(Int(count))))
}

@discardableResult
func writeGamma(_ snapshot: GammaSnapshot, to id: CGDirectDisplayID) -> CGError {
    CGSetDisplayTransferByTable(id, UInt32(snapshot.red.count), snapshot.red, snapshot.green, snapshot.blue)
}

enum DisplayError: LocalizedError {
    case failed(String)
    var errorDescription: String? { switch self { case .failed(let text): return text } }
}

// This process has no UI, network access, polling timer, or persistent recovery file.
// EOF on the private pipe means the parent exited, including SIGKILL and crashes.
func runRecoveryWatchdog() {
    var pending = Data()
    var snapshots: [GammaSnapshot] = []
    while true {
        let data = FileHandle.standardInput.availableData
        if data.isEmpty { break }
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = pending.prefix(upTo: newline)
            if let decoded = try? JSONDecoder().decode([GammaSnapshot].self, from: line) { snapshots = decoded }
            pending.removeSubrange(...newline)
        }
    }
    guard !snapshots.isEmpty, let displays = try? onlineDisplays() else { return }
    for id in displays {
        if let uuid = displayUUID(id), let saved = snapshots.first(where: { $0.uuid == uuid }) {
            writeGamma(saved, to: id)
        }
    }
}

struct DisplayInfo: Identifiable {
    let id: String
    let name: String
    let supported: Bool
    var status: String
}

@MainActor
final class DisplayController {
    private final class Table {
        let id: CGDirectDisplayID
        let baseline: GammaSnapshot
        var red: [Float]
        var green: [Float]
        var blue: [Float]
        var applied: DisplayValues?
        init(id: CGDirectDisplayID, baseline: GammaSnapshot) {
            self.id = id; self.baseline = baseline
            red = baseline.red; green = baseline.green; blue = baseline.blue
        }
    }
    private var tables: [String: Table] = [:]
    private var watchdog: Process?
    private var pipe: Pipe?
    private var armedUUIDs: Set<String> = []
    private(set) var info: [DisplayInfo] = []

    func refresh() throws {
        // Restore before capturing new baselines: never compound an existing tint.
        try restore()
        let ids = try onlineDisplays()
        tables.removeAll(); info.removeAll()
        for id in ids where CGDisplayIsInMirrorSet(id) == 0 || CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay {
            guard let uuid = displayUUID(id) else { continue }
            let name = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id })?.localizedName ?? "Display \(id)"
            do {
                let baseline = try readGamma(id)
                tables[uuid] = Table(id: id, baseline: baseline)
                info.append(DisplayInfo(id: uuid, name: name, supported: true, status: "Ready · \(baseline.red.count) calibration samples"))
            } catch {
                info.append(DisplayInfo(id: uuid, name: name, supported: false, status: error.localizedDescription))
            }
        }
    }

    private func arm(_ uuids: Set<String>) throws {
        if watchdog?.isRunning != true {
            guard let executable = Bundle.main.executableURL else { throw DisplayError.failed("Cannot find the recovery executable.") }
            let process = Process(), input = Pipe()
            process.executableURL = executable
            process.arguments = ["--recovery-watchdog"]
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            watchdog = process; pipe = input; armedUUIDs = []
        }
        guard uuids != armedUUIDs else { return }
        let snapshots = uuids.sorted().compactMap { tables[$0]?.baseline }
        var data = try JSONEncoder().encode(snapshots); data.append(10)
        guard let pipe else { throw DisplayError.failed("Display recovery is unavailable.") }
        try pipe.fileHandleForWriting.write(contentsOf: data)
        armedUUIDs = uuids
    }

    func apply(_ values: DisplayValues, preferences: [String: DisplayPreference]) throws {
        let desired = Set(tables.keys.filter { preferences[$0]?.enabled != false })
        // Arm restoration before the first display mutation.
        try arm(desired.union(tables.filter { $0.value.applied != nil }.keys))
        var errors: [String] = []
        for uuid in tables.keys.sorted() {
            guard let table = tables[uuid] else { continue }
            let p = preferences[uuid] ?? DisplayPreference()
            let target = p.useOverride ? p.values : values
            if !p.enabled {
                if table.applied != nil {
                    let result = writeGamma(table.baseline, to: table.id)
                    if result == .success { table.applied = nil; setStatus(uuid, "Excluded · calibration restored") }
                    else { errors.append("Display restore failed: \(result.rawValue)") }
                }
                continue
            }
            guard target != table.applied else { continue }
            let gains = target.gains
            for index in table.red.indices {
                table.red[index] = table.baseline.red[index] * gains[0]
                table.green[index] = table.baseline.green[index] * gains[1]
                table.blue[index] = table.baseline.blue[index] * gains[2]
            }
            let result = CGSetDisplayTransferByTable(table.id, UInt32(table.red.count), table.red, table.green, table.blue)
            if result == .success {
                table.applied = target
                setStatus(uuid, "Applied · \(Int(target.temperature)) K · \(Int(target.brightness))%")
            } else {
                // A failed write can still leave a modified device. Keep its recovery snapshot armed.
                table.applied = target
                errors.append("Display \(uuid.prefix(8)): Core Graphics error \(result.rawValue)")
                setStatus(uuid, "Apply failed · pause to restore")
            }
        }
        if !errors.isEmpty { throw DisplayError.failed(errors.joined(separator: "\n")) }
        try arm(Set(tables.filter { $0.value.applied != nil }.keys))
    }

    func restore() throws {
        let connected = Set(try onlineDisplays())
        var failed: [String] = []
        for (uuid, table) in tables where table.applied != nil {
            if !connected.contains(table.id) || displayUUID(table.id) != uuid { table.applied = nil; continue }
            let result = writeGamma(table.baseline, to: table.id)
            if result == .success { table.applied = nil; setStatus(uuid, "Original calibration restored") }
            else { failed.append("Display restore failed: \(result.rawValue)") }
        }
        if watchdog?.isRunning == true { try arm(Set(tables.filter { $0.value.applied != nil }.keys)) }
        if !failed.isEmpty { throw DisplayError.failed(failed.joined(separator: "\n")) }
    }

    func shutdown() {
        do { try restore() } catch { NSLog("Cornea Native: display restoration failed; recovery helper will retry.") }
        try? pipe?.fileHandleForWriting.close()
        watchdog?.waitUntilExit()
        pipe = nil; watchdog = nil
    }
    private func setStatus(_ uuid: String, _ text: String) {
        if let index = info.firstIndex(where: { $0.id == uuid }) { info[index].status = text }
    }
}
