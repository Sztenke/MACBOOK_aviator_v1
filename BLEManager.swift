import Foundation
import CoreBluetooth

struct BLEDevice: Identifiable {
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    var id: UUID { peripheral.identifier }
}

struct ActivityDay: Identifiable, Codable, Hashable {
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
    @Published var batteryLevel: Int?
    @Published var activityDays: [ActivityDay] = []
    @Published var diagnosticLog: [String] = []
    @Published var strideLengthCm: Double = 50.0 {
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

    // A működő verzió kulcsa: 0x1B kérést küldünk, a Mark 1 pedig
    // 20 bájtos 0x0F válaszban adja vissza a napi aktuális állapotot.
    private var awaitingCurrentStatus = false
    private var manualDisconnect = false
    private var reconnectPeripheral: CBPeripheral?

    private let dayStoreKey = "aviator.activityDays.v4"

    override init() {
        super.init()
        let savedStride = UserDefaults.standard.double(forKey: "strideLengthCm")
        if savedStride >= 30 && savedStride <= 150 { strideLengthCm = savedStride }
        loadStoredDays()
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
        manualDisconnect = false
        reconnectPeripheral = peripheral
        stopScan()
        connectedPeripheral = peripheral
        peripheral.delegate = self
        status = "Csatlakozás: \(peripheral.name ?? "ismeretlen BLE eszköz")…"
        central.connect(peripheral, options: nil)
    }

    func disconnect() {
        manualDisconnect = true
        reconnectPeripheral = nil
        guard let peripheral = connectedPeripheral else {
            status = "Nincs csatlakoztatott óra."
            return
        }
        central.cancelPeripheralConnection(peripheral)
        status = "Bluetooth kapcsolat bontása…"
    }

    func syncTime() {
        guard canWrite else {
            status = "Előbb csatlakozz az AVIATOR órához."
            return
        }
        let now = Date()
        let cal = Calendar.current
        let year = cal.component(.year, from: now)
        let bytes: [UInt8] = [
            0x6E, 0x01, 0x15,
            UInt8(year & 0xff), UInt8((year >> 8) & 0xff),
            UInt8(cal.component(.month, from: now)),
            UInt8(cal.component(.day, from: now)),
            UInt8(cal.component(.hour, from: now)),
            UInt8(cal.component(.minute, from: now)),
            UInt8(cal.component(.second, from: now)),
            0x8F
        ]
        sendCommand(bytes, label: "idő")
        status = "✓ Idő szinkronizálva."
    }

    func syncData() {
        guard canWrite else {
            status = "Előbb csatlakozz az AVIATOR órához."
            return
        }
        awaitingCurrentStatus = true

        // FONTOS: ez a működő régi verzió parancsa.
        // Nem 0x0F-et kérünk közvetlenül. A 0x1B kérésre érkezik a
        // 20 bájtos 0x0F állapotcsomag, benne a napi lépésszámmal.
        sendCommand([0x6E, 0x01, 0x1B, 0x01, 0x8F], label: "napi aktuális állapot")
        status = "Mai lépésszám és akkumulátor lekérése…"

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.awaitingCurrentStatus else { return }
            self.awaitingCurrentStatus = false
            self.status = "Nem érkezett értelmezhető napi állapotválasz."
            self.log("Napi állapot időtúllépés")
        }
    }

    func distanceKm(for steps: Int) -> Double {
        Double(steps) * strideLengthCm / 100_000.0
    }

    var currentMonthDays: [ActivityDay] {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month], from: now)
        guard let monthStart = cal.date(from: comps),
              let nextMonth = cal.date(byAdding: .month, value: 1, to: monthStart) else { return [] }
        return activityDays.filter { $0.date >= monthStart && $0.date < nextMonth }
            .sorted { $0.date < $1.date }
    }

    private var canWrite: Bool { connectedPeripheral != nil && writeCharacteristic != nil }

    private func sendCommand(_ bytes: [UInt8], label: String) {
        guard let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic else { return }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(Data(bytes), for: characteristic, type: type)
        log("TX \(label): \(hex(bytes))")
    }

    private func handleNotification(_ data: Data) {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return }
        log("RX: \(hex(bytes))")
        guard bytes.first == 0x6E, bytes.last == 0x8F else { return }

        // A régi működő app logikáját tartjuk meg: amíg napi állapotot várunk,
        // az első 20 bájtos Mark 1 csomagot értelmezzük. A gyakorlatban a
        // 0x1B kérésre 0x0F típusú, 20 bájtos válasz érkezik.
        guard awaitingCurrentStatus, bytes.count == 20 else { return }
        awaitingCurrentStatus = false

        let caloriesRaw = Int(leUInt32(bytes, 7))
        let steps = Int(leUInt32(bytes, 11))

        guard steps >= 0 && steps < 500_000 else {
            status = "A lépésszám válasza nem értelmezhető."
            log("Hibás napi lépésszám: \(steps)")
            return
        }

        // Mark 1 tesztóra: teljes töltésnél a kód 0x28. A firmware nem küld
        // külön 0–100 értéket, ezért a 0x20...0x28 tartományt százalékra skálázzuk.
        let rawBattery = Int(bytes[3])
        let battery = batteryPercent(from: rawBattery)
        batteryLevel = battery

        // A napi összesítő kcal mezőjét a korábbi verzió túl nagy számmal mutatta;
        // százados skálán jelenítjük meg, és egész kcal-ként mentjük.
        let calories = max(0, min(100_000, Int((Double(caloriesRaw) / 100.0).rounded())))

        upsertToday(steps: steps, calories: calories)
        status = "✓ Mai adatok frissítve: \(steps) lépés, akku \(battery)%"
        log("Mai állapot: \(steps) lépés | \(calories) kcal | akku \(battery)% (raw 0x\(String(format: "%02X", rawBattery)))")
    }

    private func batteryPercent(from raw: Int) -> Int {
        if raw >= 0x28 { return 100 }
        if raw <= 0x20 { return 0 }
        return Int((Double(raw - 0x20) / Double(0x28 - 0x20) * 100.0).rounded())
    }

    private func leUInt32(_ bytes: [UInt8], _ start: Int) -> UInt32 {
        guard start >= 0, start + 3 < bytes.count else { return 0 }
        return UInt32(bytes[start]) |
            (UInt32(bytes[start + 1]) << 8) |
            (UInt32(bytes[start + 2]) << 16) |
            (UInt32(bytes[start + 3]) << 24)
    }

    private func upsertToday(steps: Int, calories: Int) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        if let i = activityDays.firstIndex(where: { cal.isDate($0.date, inSameDayAs: today) }) {
            activityDays[i] = ActivityDay(date: today, steps: steps, calories: calories)
        } else {
            activityDays.append(ActivityDay(date: today, steps: steps, calories: calories))
        }
        activityDays.sort { $0.date > $1.date }
        saveStoredDays()
    }

    private func loadStoredDays() {
        guard let data = UserDefaults.standard.data(forKey: dayStoreKey),
              let saved = try? JSONDecoder().decode([ActivityDay].self, from: data) else { return }
        activityDays = saved.sorted { $0.date > $1.date }
    }

    private func saveStoredDays() {
        if let data = try? JSONEncoder().encode(activityDays) {
            UserDefaults.standard.set(data, forKey: dayStoreKey)
        }
    }

    private func upsert(_ peripheral: CBPeripheral, name: String, rssi: Int) {
        if let index = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[index] = BLEDevice(peripheral: peripheral, name: name, rssi: rssi)
        } else {
            devices.append(BLEDevice(peripheral: peripheral, name: name, rssi: rssi))
            devices.sort { $0.rssi > $1.rssi }
        }
    }

    private func log(_ text: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        diagnosticLog.append("[\(f.string(from: Date()))] \(text)")
        if diagnosticLog.count > 250 { diagnosticLog.removeFirst(diagnosticLog.count - 250) }
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
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
        manualDisconnect = false
        reconnectPeripheral = peripheral
        connectedPeripheral = peripheral
        peripheral.delegate = self
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
        connectedPeripheral = nil

        if manualDisconnect {
            status = "Az óra lecsatlakoztatva."
            return
        }

        status = "Bluetooth kapcsolat megszakadt. Újracsatlakozás…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak peripheral] in
            guard let self, let peripheral, !self.manualDisconnect else { return }
            self.connectedPeripheral = peripheral
            peripheral.delegate = self
            self.central.connect(peripheral, options: nil)
        }
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { status = "Szolgáltatás-keresési hiba: \(error.localizedDescription)"; return }
        guard let services = peripheral.services else { return }
        if let service = services.first(where: { $0.uuid == serviceUUID }) {
            peripheral.discoverCharacteristics([writeUUID, notifyUUID], for: service)
        } else {
            status = "Az AVIATOR BLE szolgáltatás nem található."
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error { status = "Karakterisztika-hiba: \(error.localizedDescription)"; return }
        for c in service.characteristics ?? [] {
            if c.uuid == writeUUID { writeCharacteristic = c }
            if c.uuid == notifyUUID {
                notifyCharacteristic = c
                peripheral.setNotifyValue(true, for: c)
            }
        }
        canSync = writeCharacteristic != nil
        status = canSync ? "AVIATOR csatlakoztatva." : "Az írási csatorna nem található."
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error { log("RX hiba: \(error.localizedDescription)"); return }
        guard characteristic.uuid == notifyUUID, let data = characteristic.value else { return }
        handleNotification(data)
    }
}
