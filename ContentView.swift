import SwiftUI

private enum ActivityMetric: String, CaseIterable, Identifiable {
    case steps = "Lépés"
    case distance = "Távolság"
    case calories = "Kalória"

    var id: String { rawValue }
}

private enum ActivityRange: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30

    var id: Int { rawValue }
    var title: String { rawValue == 7 ? "7 nap" : "30 nap" }
}

struct ContentView: View {
    @StateObject private var ble = BLEManager()
    @State private var selectedTab = 0
    @State private var chartMetric: ActivityMetric = .steps
    @State private var chartRange: ActivityRange = .week
    @State private var showDiagnostics = false

    var body: some View {
        VStack(spacing: 12) {
            header

            TabView(selection: $selectedTab) {
                overviewTab
                    .tabItem { Label("Áttekintés", systemImage: "clock.arrow.circlepath") }
                    .tag(0)

                activityTab
                    .tabItem { Label("Aktivitás", systemImage: "figure.walk") }
                    .tag(1)

                chartsTab
                    .tabItem { Label("Grafikonok", systemImage: "chart.bar.xaxis") }
                    .tag(2)

                diagnosticsTab
                    .tabItem { Label("Diagnosztika", systemImage: "waveform.path.ecg") }
                    .tag(3)
            }
        }
        .padding(18)
        .frame(minWidth: 820, minHeight: 720)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AVIATOR Sync")
                    .font(.largeTitle.bold())
                Text("F-Series Mark 1 / AVW79215G360")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(ble.bluetoothReady ? Color.green : Color.orange)
                .frame(width: 11, height: 11)
            Text(ble.bluetoothReady ? "Bluetooth kész" : "Bluetooth nem kész")
                .foregroundStyle(.secondary)
        }
    }

    private var overviewTab: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                GroupBox("A Mac aktuális ideje") {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(context.date.formatted(date: .abbreviated, time: .standard))
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                }

                GroupBox("Távolság számítása") {
                    HStack {
                        Text("Lépéshossz")
                            .foregroundStyle(.secondary)
                        TextField("75", value: $ble.strideLengthCm,
                                  format: .number.precision(.fractionLength(0)))
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                        Text("cm")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }

            connectionBox

            HStack {
                Button("Csak idő szinkronizálása") { ble.syncTime() }
                    .disabled(!ble.canSync)

                Button(ble.isActivitySyncing ? "Aktivitás szinkronizálása…" : "Idő + aktivitás szinkronizálása") {
                    ble.syncTimeAndActivity()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ble.canSync || ble.isActivitySyncing)

                Spacer()
                Text("\(ble.totalStoredDays) nap eltárolva")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let today = todayActivity {
                HStack(spacing: 12) {
                    summaryCard(title: "Mai lépések", value: "\(today.steps)", icon: "figure.walk")
                    summaryCard(title: "Mai távolság", value: String(format: "%.2f km", ble.distanceKm(for: today.steps)), icon: "location")
                    summaryCard(title: "Mai kalória", value: "\(today.calories) kcal", icon: "flame")
                }
            } else {
                GroupBox {
                    Text("Még nincs mai aktivitási adat. Csatlakozz az órához, majd indítsd el az idő + aktivitás szinkronizálását.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
            }

            Spacer(minLength: 4)
            statusLine
        }
        .padding(.top, 8)
    }

    private var connectionBox: some View {
        GroupBox("Kapcsolat") {
            VStack(spacing: 8) {
                HStack {
                    Button(ble.isScanning ? "Keresés folyamatban…" : "BLE eszközök keresése") {
                        ble.startScan()
                    }
                    .disabled(!ble.bluetoothReady || ble.isScanning)

                    Button("Keresés leállítása") { ble.stopScan() }
                        .disabled(!ble.isScanning)
                    Spacer()
                    Button("Lista törlése") { ble.clearDevices() }
                        .disabled(ble.devices.isEmpty)
                }

                List(ble.devices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.headline)
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
                    .padding(.vertical, 2)
                }
                .frame(height: 180)
            }
            .padding(4)
        }
    }

    private var activityTab: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Aktivitási előzmények")
                    .font(.title2.bold())
                Spacer()
                Text("\(ble.totalStoredDays) nap")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(spacing: 0) {
                    HStack {
                        Text("Dátum").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Lépés").frame(width: 110, alignment: .trailing)
                        Text("Távolság").frame(width: 120, alignment: .trailing)
                        Text("Kalória").frame(width: 110, alignment: .trailing)
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)

                    Divider()

                    if ble.activityDays.isEmpty {
                        Text("Még nincs letöltött aktivitási adat.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    } else {
                        List(ble.activityDays) { day in
                            HStack {
                                Text(day.date.formatted(date: .numeric, time: .omitted))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(day.steps)")
                                    .monospacedDigit()
                                    .frame(width: 110, alignment: .trailing)
                                Text(String(format: "%.2f km", ble.distanceKm(for: day.steps)))
                                    .monospacedDigit()
                                    .frame(width: 120, alignment: .trailing)
                                Text("\(day.calories) kcal")
                                    .monospacedDigit()
                                    .frame(width: 110, alignment: .trailing)
                            }
                        }
                    }
                }
            }

            statusLine
        }
        .padding(.top, 8)
    }

    private var chartsTab: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Aktivitási grafikonok")
                    .font(.title2.bold())
                Spacer()
                Picker("Időtáv", selection: $chartRange) {
                    ForEach(ActivityRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            Picker("Mutató", selection: $chartMetric) {
                ForEach(ActivityMetric.allCases) { metric in
                    Text(metric.rawValue).tag(metric)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 430)

            let days = chartDays
            HStack(spacing: 12) {
                summaryCard(title: "Összes lépés", value: "\(days.reduce(0) { $0 + $1.steps })", icon: "figure.walk")
                summaryCard(title: "Összes távolság", value: String(format: "%.2f km", days.reduce(0.0) { $0 + ble.distanceKm(for: $1.steps) }), icon: "location")
                summaryCard(title: "Összes kalória", value: "\(days.reduce(0) { $0 + $1.calories }) kcal", icon: "flame")
            }

            GroupBox {
                if days.isEmpty {
                    Text("Nincs még elegendő aktivitási adat a grafikonhoz.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ActivityBarChart(days: days,
                                     metric: chartMetric,
                                     distanceProvider: ble.distanceKm(for:))
                        .frame(minHeight: 320)
                        .padding(10)
                }
            }

            HStack {
                Text("A grafikon a Macen eltárolt, óráról szinkronizált napi adatokat mutatja.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            statusLine
        }
        .padding(.top, 8)
    }

    private var diagnosticsTab: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Bluetooth diagnosztika")
                    .font(.title2.bold())
                Spacer()
                Text("Mark 1 protokoll")
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(ble.diagnosticLog.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color.primary.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            statusLine
        }
        .padding(.top, 8)
    }

    private func summaryCard(title: String, value: String, icon: String) -> some View {
        GroupBox {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.title3.bold())
                        .monospacedDigit()
                }
                Spacer()
            }
            .padding(5)
        }
        .frame(maxWidth: .infinity)
    }

    private var statusLine: some View {
        Text(ble.status)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    private var todayActivity: ActivityDay? {
        let cal = Calendar.current
        return ble.activityDays.first { cal.isDateInToday($0.date) }
    }

    private var chartDays: [ActivityDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let cutoff = calendar.date(byAdding: .day, value: -(chartRange.rawValue - 1), to: today) ?? today
        return ble.activityDays
            .filter { $0.date >= cutoff && $0.date <= today }
            .sorted { $0.date < $1.date }
    }
}

private struct ActivityBarChart: View {
    let days: [ActivityDay]
    let metric: ActivityMetric
    let distanceProvider: (Int) -> Double

    private var values: [Double] {
        days.map { day in
            switch metric {
            case .steps: return Double(day.steps)
            case .distance: return distanceProvider(day.steps)
            case .calories: return Double(day.calories)
            }
        }
    }

    private var maxValue: Double {
        max(values.max() ?? 0, 1)
    }

    private func valueText(_ value: Double) -> String {
        switch metric {
        case .steps: return String(Int(value.rounded()))
        case .distance: return String(format: "%.2f km", value)
        case .calories: return "\(Int(value.rounded())) kcal"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let count = max(days.count, 1)
            let spacing: CGFloat = days.count > 14 ? 3 : 7
            let totalSpacing = spacing * CGFloat(max(count - 1, 0))
            let barWidth = max(4, (geometry.size.width - totalSpacing) / CGFloat(count))
            let chartHeight = max(geometry.size.height - 42, 1)

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(zip(days.indices, days)), id: \.1.id) { index, day in
                    let value = values[index]
                    VStack(spacing: 4) {
                        Spacer(minLength: 0)
                        Text(valueText(value))
                            .font(.system(size: days.count > 14 ? 7 : 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .opacity(days.count > 14 && index % 5 != 0 ? 0 : 1)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.tint)
                            .frame(width: barWidth,
                                   height: max(2, chartHeight * CGFloat(value / maxValue)))
                        Text(day.date.formatted(.dateTime.day().month(.abbreviated)))
                            .font(.system(size: days.count > 14 ? 7 : 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .opacity(days.count > 14 && index % 3 != 0 ? 0 : 1)
                    }
                    .frame(width: barWidth)
                }
            }
        }
    }
}
