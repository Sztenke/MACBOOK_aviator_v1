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
    @Published var batteryRaw: Int?
    @Published var activityDays: [ActivityDay] = []
    @Published var diagnosticLog: [String] = []

    // Ezeket egyszer az óra kijelzett értékeihez kalibráljuk.
    @Published var distancePerStepKm: Double = 0.0005 {
        didSet { UserDefaults.standard.set(distancePerStepKm, forKey: "aviator.distancePerStepKm") }
    }
    @Published var caloriesPerStep: Double = 0.04 {
        didSet { UserDefaults.standard.set(caloriesPerStep, forKey: "aviator.caloriesPerStep") }
    }

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    private let serviceUUID = CBUUID(string: "00006006-0000-1000-8000-00805F9B34FB")
    private let writeUUID = CBUUID(string: "00008001-0000-1000-8000-00805F9B34FB")
    private let notifyUUID = CBUUID(string: "00008002-0000-1000-8000-00805F9B34FB")

    // A működő verzióból visszaállított Mark 1 lekérés.
    private var awaitingCurrentStatus = false
    private var manualDisconnect = false
    private var reconnectPeripheral: CBPeripheral?
    private let dayStoreKey = "aviator.activityDays.v4"

    override init() {
        super.init()
        let d = UserDefaults.standard.double(forKey: "aviator.distancePerStepKm")
        let c = UserDefaults.standard.double(forKey: "aviator.caloriesPerStep")
        if d > 0 { distancePerStepKm = d }
        if c > 0 { caloriesPerStep = c }
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
        status = "AVIATOR óra keresése…"
        // Nem korlátozzuk a rádiós keresést kizárólag service UUID-ra, mert egyes Mark 1
        // példányok nem minden advertising csomagban hirdetik a 6006 szolgáltatást.
        // A találatokat a didDiscover-ben szűrjük, így a listában csak AVIATOR jelenik meg.
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
        // Ez az a kérés, amellyel a felhasználónál ténylegesen működött a napi lépésszám.
        sendCommand([0x6E, 0x01, 0x1B, 0x01, 0x8F], label: "napi aktuális állapot")
        status = "Mai lépésszám és akkumulátor lekérése…"

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.awaitingCurrentStatus else { return }
            self.awaitingCurrentStatus = false
            self.status = "Nem érkezett értelmezhető napi állapotválasz."
            self.log("Napi állapot időtúllépés")
        }
    }

    var todaySteps: Int? {
        activityDays.first { Calendar.current.isDateInToday($0.date) }?.steps
    }

    func distanceKm(for steps: Int) -> Double {
        Double(steps) * distancePerStepKm
    }

    func calories(for steps: Int) -> Int {
        max(0, Int((Double(steps) * caloriesPerStep).rounded()))
    }

    func calibrate(distanceKm: Double, calories: Double) -> Bool {
        guard let steps = todaySteps, steps > 0, distanceKm > 0, calories > 0 else {
            status = "Előbb szinkronizáld a mai lépésszámot, majd add meg az órán látható km és kcal értéket."
            return false
        }
        distancePerStepKm = distanceKm / Double(steps)
        caloriesPerStep = calories / Double(steps)
        // A mai napot újramentjük, hogy az összes nézet azonnal frissüljön.
        upsertToday(steps: steps)
        status = String(format: "✓ Kalibrálva: %.2f km és %.0f kcal / %d lépés", distanceKm, calories, steps)
        log(String(format: "Kalibráció: %d lépés -> %.2f km, %.0f kcal", steps, distanceKm, calories))
        return true
    }

    func days(in month: Date) -> [ActivityDay] {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: month)
        guard let start = cal.date(from: comps),
              let next = cal.date(byAdding: .month, value: 1, to: start) else { return [] }
        return activityDays.filter { $0.date >= start && $0.date < next }.sorted { $0.date < $1.date }
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
        guard awaitingCurrentStatus, bytes.count == 20 else { return }
        awaitingCurrentStatus = false

        // A működő verzió mezője: [11...14] little-endian = mai lépésszám.
        let steps = Int(leUInt32(bytes, 11))
        guard steps >= 0 && steps < 500_000 else {
            status = "A lépésszám válasza nem értelmezhető."
            log("Hibás napi lépésszám: \(steps)")
            return
        }

        // A Mark 1 teljes töltésnél 0x28 (=40) értéket küldött.
        // Ezt 0...40 skálaként kezeljük és 0...100%-ra alakítjuk.
        let rawBattery = Int(bytes[3])
        batteryRaw = rawBattery
        let battery = max(0, min(100, Int((Double(rawBattery) / 40.0 * 100.0).rounded())))
        batteryLevel = battery

        upsertToday(steps: steps)
        status = "✓ Mai adatok frissítve: \(steps) lépés, akku \(battery)%"
        log("Mai állapot: \(steps) lépés | akku \(battery)% (raw \(rawBattery))")
    }

    private func leUInt32(_ bytes: [UInt8], _ start: Int) -> UInt32 {
        guard start >= 0, start + 3 < bytes.count else { return 0 }
        return UInt32(bytes[start]) |
            (UInt32(bytes[start + 1]) << 8) |
            (UInt32(bytes[start + 2]) << 16) |
            (UInt32(bytes[start + 3]) << 24)
    }

    private func upsertToday(steps: Int) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let derivedCalories = calories(for: steps)
        if let i = activityDays.firstIndex(where: { cal.isDate($0.date, inSameDayAs: today) }) {
            activityDays[i] = ActivityDay(date: today, steps: steps, calories: derivedCalories)
        } else {
            activityDays.append(ActivityDay(date: today, steps: steps, calories: derivedCalories))
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
        if bluetoothReady { status = "Bluetooth kész" }
        else { status = "Bluetooth nem elérhető (állapot: \(central.state.rawValue))" }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? "Névtelen BLE eszköz"
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let isAviatorName = name.lowercased().contains("aviator")
        let hasAviatorService = serviceUUIDs.contains(serviceUUID)

        // A felületen kizárólag AVIATOR óra jelenjen meg.
        guard isAviatorName || hasAviatorService else { return }
        upsert(peripheral, name: name, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        connectedID = peripheral.identifier
        manualDisconnect = false
        status = "Csatlakozva. Szolgáltatások keresése…"
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectedID = nil; canSync = false
        status = "Csatlakozási hiba: \(error?.localizedDescription ?? "ismeretlen")"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        connectedID = nil; canSync = false
        connectedPeripheral = nil; writeCharacteristic = nil; notifyCharacteristic = nil
        awaitingCurrentStatus = false
        if manualDisconnect {
            status = "Az óra kézzel lecsatlakoztatva."
            return
        }
        status = "Kapcsolat megszakadt. Újracsatlakozás…"
        let target = reconnectPeripheral ?? peripheral
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak target] in
            guard let self, let target, !self.manualDisconnect else { return }
            self.connectedPeripheral = target
            target.delegate = self
            self.central.connect(target, options: nil)
        }
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { status = "Szolgáltatás hiba: \(error!.localizedDescription)"; return }
        guard let services = peripheral.services else { return }
        for s in services where s.uuid == serviceUUID {
            peripheral.discoverCharacteristics([writeUUID, notifyUUID], for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { status = "Karakterisztika hiba: \(error!.localizedDescription)"; return }
        for c in service.characteristics ?? [] {
            if c.uuid == writeUUID { writeCharacteristic = c }
            if c.uuid == notifyUUID {
                notifyCharacteristic = c
                peripheral.setNotifyValue(true, for: c)
            }
        }
        canSync = writeCharacteristic != nil && notifyCharacteristic != nil
        if canSync { status = "✓ AVIATOR Mark 1 készen áll." }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        handleNotification(data)
    }
}
