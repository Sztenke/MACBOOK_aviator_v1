import SwiftUI

struct ContentView: View {
    @StateObject private var ble = BLEManager()

    var body: some View {
        VStack(spacing: 18) {
            Text("AVIATOR Sync")
                .font(.largeTitle.bold())

            Text("F-Series Mark 1 / AVW79215G360")
                .foregroundStyle(.secondary)

            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("A Mac aktuális ideje")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(context.date.formatted(date: .abbreviated, time: .standard))
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    }
                }
                Spacer()
                Circle()
                    .fill(ble.bluetoothReady ? Color.green : Color.orange)
                    .frame(width: 12, height: 12)
                Text(ble.bluetoothReady ? "Bluetooth kész" : "Bluetooth nem kész")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(ble.isScanning ? "Keresés folyamatban…" : "BLE eszközök keresése") {
                    ble.startScan()
                }
                .disabled(!ble.bluetoothReady || ble.isScanning)

                Button("Keresés leállítása") {
                    ble.stopScan()
                }
                .disabled(!ble.isScanning)

                Spacer()

                Button("Lista törlése") {
                    ble.clearDevices()
                }
                .disabled(ble.devices.isEmpty)
            }

            List(ble.devices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name)
                            .font(.headline)
                        Text(device.id.uuidString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("RSSI \(device.rssi)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(ble.connectedID == device.id ? "Csatlakozva" : "Csatlakozás") {
                        ble.connect(to: device.peripheral)
                    }
                    .disabled(ble.connectedID == device.id)
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 260)

            Button("Mac dátumának és idejének szinkronizálása az órára") {
                ble.syncTime()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!ble.canSync)

            Text(ble.status)
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(24)
    }
}
