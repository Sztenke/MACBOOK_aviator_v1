import Foundation
import CoreBluetooth

struct BLEDevice: Identifiable {
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    var id: UUID { peripheral.identifier }
}

struct ActivityRecord: Codable, Hashable {
    let rawTimestamp: UInt32
    let date: Date
    let steps: Int
    let calories: Int
}

struct ActivityDay: Identifiable, Hashable {
    let date: Date
    let steps: Int
    let calories: Int
    var id: Date { date }
}

final class BLEManager: NSObject, ObservableObject {
    @Published var devices: [BLEDevice] = []
    @Published var status = "Bluetooth inicializálása…"
    @Published var isScanning = false
    @Published var connectedID: UUID?
    @Published var bluetoothReady = false
    @Published var canSync = false
    @Published var isActivitySyncing = false
    @Published var batteryLevel: Int? = nil
    @Published var activityDays: [ActivityDay] = []
    @Published var diagnosticLog: [String] = []
    @Published var strideLengthCm: Double = 75.0 {
        didSet {
            let safe = min(max(strideLengthCm, 30), 150)
            if safe != strideLengthCm { strideLengthCm = safe }
            UserDefaults.standard.set(strideLengthCm, forKey: "strideLengthCm")
        }
    }

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    private let serviceUUID = CBUUID(string: "00006006-0000-1000-8000-00805F9B34FB")
    private let writeUUID = CBUUID(string: "00008001-0000-1000-8000-00805F9B34FB")
    private let notifyUUID = CBUUID(string: "00008002-0000-1000-8000-00805F9B34FB")

    private var recordsByTimestamp: [UInt32: ActivityRecord] = [:]
    private var currentTodaySteps: Int?
    private var currentTodayCalories: Int?
    private var awaitingCurrentTotals = false
    private var awaitingBattery = false
    private var sportRequestCount = 0
    private let maxSportRequests = 1000
    private let recordsDefaultsKey = "aviator.activityRecords.v3"

    override init() {
        super.init()
        let savedStride = UserDefaults.standard.double(forKey: "strideLengthCm")
        if savedStride >= 30 && savedStride <= 150 { strideLengthCm = savedStride }
        loadStoredActivity()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func clearDevices() { devices.removeAll() }

    func startScan() {
        guard central.state == .poweredOn else {
            status = "A Bluetooth nincs bekapcsolva vagy még nem áll készen."
            return
        }
        devices.removeAll()
        isScanning = true
        status = "Közeli BLE eszközök keresése…"
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        if connectedPeripheral == nil { status = "Keresés leállítva." }
    }

    func connect(to peripheral: CBPeripheral) {
        stopScan()
        connectedPeripheral = peripheral
        peripheral.delegate = self
        status = "Csatlakozás: \(peripheral.name ?? "ismeretlen BLE eszköz")…"
        central.connect(peripheral, options: nil)
    }

    func syncTime() {
        guard canWrite else {
            status = "Előbb csatlakozz az AVIATOR órához."
            return
        }
        sendTimePacket()
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else {
            status = "Nincs csatlakoztatott óra."
            return
        }
        central.cancelPeripheralConnection(peripheral)
        status = "Bluetooth kapcsolat bontása…"
    }

    func syncData() {
        guard canWrite else {
            status = "Előbb csatlakozz az AVIATOR órához."
            return
        }
        awaitingBattery = true
        sendCommand([0x6E, 0x01, 0x0F, 0x01, 0x8F], label: "akkumulátor")
        status = "Akkumulátor és aktivitási adatok lekérése…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            self?.startActivitySync()
        }
    }

    func syncTimeAndActivity() {
        guard canWrite else {
            status = "Előbb csatlakozz az AVIATOR órához."
            return
        }
        sendTimePacket()
        status = "Idő elküldve. Aktivitási adatok lekérése indul…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.startActivitySync()
        }
    }

    func startActivitySync() {
        guard canWrite else {
            status = "Előbb csatlakozz az AVIATOR órához."
            return
        }
        isActivitySyncing = true
        sportRequestCount = 0
        currentTodaySteps = nil
        currentTodayCalories = nil
        awaitingCurrentTotals = true
        log("Aktivitás-szinkron indítása")

        // Eredeti Mark 1 app: getSportDataTotal
        sendCommand([0x6E, 0x01, 0x1B, 0x01, 0x8F], label: "napi összesítő")

        // Eredeti Mark 1 app: getSportDataDetail
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            self?.requestNextSportRecord()
        }
    }

    func distanceKm(for steps: Int) -> Double {
        Double(steps) * strideLengthCm / 100_000.0
    }

    var totalStoredDays: Int { activityDays.count }

    private var canWrite: Bool {
        connectedPeripheral != nil && writeCharacteristic != nil
    }

    private func sendTimePacket() {
        let now = Date()
        let cal = Calendar.current
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)
        let day = cal.component(.day, from: now)
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let second = cal.component(.second, from: now)

        let bytes: [UInt8] = [
            0x6E, 0x01, 0x15,
            UInt8(year & 0xff), UInt8((year >> 8) & 0xff),
            UInt8(month), UInt8(day), UInt8(hour), UInt8(minute), UInt8(second),
            0x8F
        ]
        sendCommand(bytes, label: "idő")
        status = String(format: "Időcsomag elküldve: %04d-%02d-%02d %02d:%02d:%02d",
                        year, month, day, hour, minute, second)
    }

    private func requestNextSportRecord() {
        guard isActivitySyncing else { return }
        guard sportRequestCount < maxSportRequests else {
            finishActivitySync(message: "A lekérés biztonsági limitnél megállt.")
            return
        }
        sportRequestCount += 1
        sendCommand([0x6E, 0x01, 0x06, 0x01, 0x8F], label: "aktivitás rekord #\(sportRequestCount)")
    }

    private func sendCommand(_ bytes: [UInt8], label: String) {
        guard let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic else { return }
        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(Data(bytes), for: characteristic, type: type)
        log("TX \(label): \(hex(bytes))")
    }

    private func handleNotification(_ data: Data) {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return }
        log("RX: \(hex(bytes))")

        // A Mark 1 válaszcsomagok 0x6E fejléccel és 0x8F lezárással érkeznek.
        guard bytes.first == 0x6E, bytes.last == 0x8F else { return }

        // Mark 1 akkumulátor-lekérés válasza. A diagnosztikai naplóban a teljes
        // csomagot is megtartjuk, így firmware-eltérés esetén pontosítható a dekódolás.
        if awaitingBattery && bytes.count >= 5 {
            if bytes.contains(0x0F) {
                let body = bytes.dropFirst(3).dropLast()
                if let level = body.first(where: { $0 <= 100 }) {
                    batteryLevel = Int(level)
                    log("Akkumulátor: \(level)%")
                }
                awaitingBattery = false
                return
            }
        }

        // Napi aktuális összesítő. A gyári appban a 20 bájtos válaszból:
        // [7...10] = calories, [11...14] = steps (little endian).
        if awaitingCurrentTotals && bytes.count == 20 {
            let calories = Int(leUInt32(bytes, 7))
            let steps = Int(leUInt32(bytes, 11))
            if steps >= 0 && steps < 500_000 && calories >= 0 && calories < 100_000 {
                currentTodaySteps = steps
                currentTodayCalories = calories
                log("Mai összesítő: \(steps) lépés, \(calories) kcal")
                rebuildActivityDays()
            }
            awaitingCurrentTotals = false
            return
        }

        // Sport detail rekord: 19 bájt; a gyári app SportsData objektumot készít belőle.
        if bytes.count == 19 && bytes.count > 18 && bytes[2] == 0x05 {
            let payloadIsZero = bytes[4...15].allSatisfy { $0 == 0 }
            if bytes[3] == 0x06 && payloadIsZero {
                finishActivitySync(message: "✓ Aktivitási adatok szinkronizálva.")
                return
            }

            let rawTime = leUInt32(bytes, 4)
            let steps = Int(leUInt32(bytes, 8))
            let calories = Int(leUInt32(bytes, 12))

            if let date = decodeWatchDate(rawTime),
               steps >= 0, steps < 500_000,
               calories >= 0, calories < 100_000 {
                let record = ActivityRecord(rawTimestamp: rawTime,
                                            date: date,
                                            steps: steps,
                                            calories: calories)
                recordsByTimestamp[rawTime] = record // duplikáció ellen
                saveStoredActivity()
                rebuildActivityDays()
                log("Rekord: \(date.formatted()) | \(steps) lépés | \(calories) kcal")
            } else {
                log("Nem értelmezhető sport rekord; rawTime=\(rawTime), steps=\(steps), cal=\(calories)")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
                self?.requestNextSportRecord()
            }
            return
        }

        // Néhány firmware a befejező választ rövidebb csomagban küldheti.
        if isActivitySyncing && bytes.count <= 8 && bytes.contains(0x06) {
            finishActivitySync(message: "✓ Aktivitási adatok szinkronizálva.")
        }
    }

    private func finishActivitySync(message: String) {
        isActivitySyncing = false
        awaitingCurrentTotals = false
        rebuildActivityDays()
        status = message + " \(activityDays.count) nap helyben eltárolva."
        log(status)
    }

    private func leUInt32(_ bytes: [UInt8], _ start: Int) -> UInt32 {
        guard start >= 0, start + 3 < bytes.count else { return 0 }
        return UInt32(bytes[start]) |
               (UInt32(bytes[start + 1]) << 8) |
               (UInt32(bytes[start + 2]) << 16) |
               (UInt32(bytes[start + 3]) << 24)
    }

    private func decodeWatchDate(_ raw: UInt32) -> Date? {
        let candidates = [
            Date(timeIntervalSince1970: TimeInterval(raw)),
            Date(timeIntervalSince1970: TimeInterval(raw) + 946_684_800) // 2000-01-01 epoch fallback
        ]
        let calendar = Calendar.current
        return candidates.first {
            let y = calendar.component(.year, from: $0)
            return y >= 2015 && y <= 2100
        }
    }

    private func rebuildActivityDays() {
        let cal = Calendar.current
        var grouped: [Date: (steps: Int, calories: Int)] = [:]

        for record in recordsByTimestamp.values {
            let day = cal.startOfDay(for: record.date)
            let old = grouped[day] ?? (0, 0)
            grouped[day] = (old.steps + record.steps, old.calories + record.calories)
        }

        // A jelenlegi nap összesítője abszolút napi érték; ha nagyobb a részrekordok
        // összegénél, ezt tekintjük a legfrissebb mai értéknek.
        if let steps = currentTodaySteps, let calories = currentTodayCalories {
            let today = cal.startOfDay(for: Date())
            let old = grouped[today] ?? (0, 0)
            grouped[today] = (max(old.steps, steps), max(old.calories, calories))
        }

        activityDays = grouped.map { ActivityDay(date: $0.key, steps: $0.value.steps, calories: $0.value.calories) }
            .sorted { $0.date > $1.date }
    }

    private func saveStoredActivity() {
        let records = Array(recordsByTimestamp.values)
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: recordsDefaultsKey)
        }
    }

    private func loadStoredActivity() {
        guard let data = UserDefaults.standard.data(forKey: recordsDefaultsKey),
              let records = try? JSONDecoder().decode([ActivityRecord].self, from: data) else {
            return
        }
        recordsByTimestamp = Dictionary(uniqueKeysWithValues: records.map { ($0.rawTimestamp, $0) })
        rebuildActivityDays()
    }

    private func log(_ text: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        diagnosticLog.append("[\(stamp)] \(text)")
        if diagnosticLog.count > 300 { diagnosticLog.removeFirst(diagnosticLog.count - 300) }
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func upsert(_ peripheral: CBPeripheral, name: String, rssi: Int) {
        if let index = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[index] = BLEDevice(peripheral: peripheral, name: name, rssi: rssi)
        } else {
            devices.append(BLEDevice(peripheral: peripheral, name: name, rssi: rssi))
            devices.sort { $0.rssi > $1.rssi }
        }
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothReady = central.state == .poweredOn
        switch central.state {
        case .poweredOn: status = "Bluetooth kész. Keresd meg az AVIATOR órát."
        case .poweredOff: status = "Kapcsold be a Bluetooth-t a Macen."
        case .unauthorized: status = "A macOS nem engedélyezte a Bluetooth-hozzáférést."
        case .unsupported: status = "Ez a Mac nem támogatja a szükséges Bluetooth LE funkciót."
        case .resetting: status = "Bluetooth újraindul…"
        default: status = "Bluetooth inicializálása…"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? "Névtelen BLE eszköz"
        upsert(peripheral, name: name, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedID = peripheral.identifier
        status = "Csatlakozva. AVIATOR BLE szolgáltatás keresése…"
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        connectedID = nil
        status = "Nem sikerült csatlakozni: \(error?.localizedDescription ?? "ismeretlen hiba")"
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        connectedID = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        canSync = false
        isActivitySyncing = false
        connectedPeripheral = nil
        batteryLevel = nil
        status = "Az óra lecsatlakoztatva."
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            status = "Service keresési hiba: \(error.localizedDescription)"
            return
        }
        guard let services = peripheral.services else {
            status = "A csatlakoztatott eszköz nem adott vissza BLE szolgáltatásokat."
            return
        }
        if let aviatorService = services.first(where: { $0.uuid == serviceUUID }) {
            status = "AVIATOR 6006 service megtalálva. Karakterisztikák keresése…"
            peripheral.discoverCharacteristics(nil, for: aviatorService)
        } else {
            let found = services.map { $0.uuid.uuidString }.joined(separator: ", ")
            status = "Csatlakozott, de a 6006 AVIATOR service nincs rajta. Talált service-ek: \(found)"
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            status = "Karakterisztika keresési hiba: \(error.localizedDescription)"
            return
        }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == writeUUID { writeCharacteristic = characteristic }
            if characteristic.uuid == notifyUUID {
                notifyCharacteristic = characteristic
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
        if writeCharacteristic != nil {
            canSync = true
            status = "AVIATOR kommunikáció kész."
        } else {
            let found = (service.characteristics ?? []).map { $0.uuid.uuidString }.joined(separator: ", ")
            status = "A 8001 írási karakterisztika nem található. Talált karakterisztikák: \(found)"
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            log("Notify hiba: \(error.localizedDescription)")
            return
        }
        guard characteristic.uuid == notifyUUID, let data = characteristic.value else { return }
        handleNotification(data)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            status = "Bluetooth írási hiba: \(error.localizedDescription)"
            log(status)
        }
    }
}
