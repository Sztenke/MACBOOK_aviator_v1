import Foundation
import CoreBluetooth

struct BLEDevice: Identifiable {
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    var id: UUID { peripheral.identifier }
}

final class BLEManager: NSObject, ObservableObject {
    @Published var devices: [BLEDevice] = []
    @Published var status = "Bluetooth inicializálása…"
    @Published var isScanning = false
    @Published var connectedID: UUID?
    @Published var bluetoothReady = false
    @Published var canSync = false

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?

    // Az eredeti AVIATOR F-Series Mark 1 alkalmazásból visszafejtett UUID-k.
    private let serviceUUID = CBUUID(string: "00006006-0000-1000-8000-00805F9B34FB")
    private let writeUUID = CBUUID(string: "00008001-0000-1000-8000-00805F9B34FB")
    private let notifyUUID = CBUUID(string: "00008002-0000-1000-8000-00805F9B34FB")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func clearDevices() {
        devices.removeAll()
    }

    func startScan() {
        guard central.state == .poweredOn else {
            status = "A Bluetooth nincs bekapcsolva vagy még nem áll készen."
            return
        }
        devices.removeAll()
        isScanning = true
        status = "Közeli BLE eszközök keresése…"
        // Szándékosan nincs service filter: a régi óra akkor is megjelenhet,
        // ha a 6006 service UUID-t nem hirdeti az advertising csomagban.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        if connectedPeripheral == nil {
            status = "Keresés leállítva."
        }
    }

    func connect(to peripheral: CBPeripheral) {
        stopScan()
        connectedPeripheral = peripheral
        peripheral.delegate = self
        status = "Csatlakozás: \(peripheral.name ?? "ismeretlen BLE eszköz")…"
        central.connect(peripheral, options: nil)
    }

    func syncTime() {
        guard let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic else {
            status = "Előbb csatlakozz az AVIATOR órához."
            return
        }

        let now = Date()
        let cal = Calendar.current
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)
        let day = cal.component(.day, from: now)
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let second = cal.component(.second, from: now)

        // Az eredeti Mark 1 app syncTimeToDevice() formátuma:
        // 6E 01 15 YYlo YYhi MM DD HH mm ss 8F
        let bytes: [UInt8] = [
            0x6E, 0x01, 0x15,
            UInt8(year & 0xff),
            UInt8((year >> 8) & 0xff),
            UInt8(month), UInt8(day), UInt8(hour), UInt8(minute), UInt8(second),
            0x8F
        ]

        let writeType: CBCharacteristicWriteType =
            characteristic.properties.contains(.write) ? .withResponse : .withoutResponse

        peripheral.writeValue(Data(bytes), for: characteristic, type: writeType)
        status = String(format: "Időcsomag elküldve: %04d-%02d-%02d %02d:%02d:%02d",
                        year, month, day, hour, minute, second)
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
        case .poweredOn:
            status = "Bluetooth kész. Nyomd meg a BLE eszközök keresése gombot."
        case .poweredOff:
            status = "Kapcsold be a Bluetooth-t a Macen."
        case .unauthorized:
            status = "A macOS nem engedélyezte a Bluetooth-hozzáférést."
        case .unsupported:
            status = "Ez a Mac nem támogatja a szükséges Bluetooth LE funkciót."
        case .resetting:
            status = "Bluetooth újraindul…"
        default:
            status = "Bluetooth inicializálása…"
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
        canSync = false
        status = "Az óra kapcsolata megszakadt."
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
            if characteristic.uuid == writeUUID {
                writeCharacteristic = characteristic
            }
            if characteristic.uuid == notifyUUID,
               characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }

        if writeCharacteristic != nil {
            canSync = true
            status = "AVIATOR kommunikáció kész. Szinkronizálhatod a Mac idejét."
        } else {
            let found = (service.characteristics ?? []).map { $0.uuid.uuidString }.joined(separator: ", ")
            status = "A 8001 írási karakterisztika nem található. Talált karakterisztikák: \(found)"
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            status = "Bluetooth írási hiba: \(error.localizedDescription)"
        } else {
            status = "✓ A Mac pontos dátuma és ideje elküldve az AVIATOR órának."
        }
    }
}
