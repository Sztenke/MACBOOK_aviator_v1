import SwiftUI

private enum Metric: String, CaseIterable, Identifiable {
    case steps = "Lépés"
    case distance = "Távolság"
    case calories = "Kalória"
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var ble = BLEManager()
    @State private var selectedTab = 0
    @State private var metric: Metric = .steps

    var body: some View {
        VStack(spacing: 10) {
            header
            TabView(selection: $selectedTab) {
                overview.tag(0).tabItem { Label("Áttekintés", systemImage: "gauge") }
                monthly.tag(1).tabItem { Label("Havi grafikon", systemImage: "chart.bar.fill") }
                diagnostics.tag(2).tabItem { Label("Diagnosztika", systemImage: "stethoscope") }
            }
        }
        .padding(18)
        .frame(minWidth: 900, minHeight: 680)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("AVIATOR Sync").font(.largeTitle.bold())
                Text("F-Series Mark 1 / AVW79215G360").foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(ble.connectedID == nil ? Color.secondary : Color.green).frame(width: 11, height: 11)
            Text(ble.connectedID == nil ? "Nincs kapcsolat" : "AVIATOR csatlakoztatva").foregroundStyle(.secondary)
        }
    }

    private var overview: some View {
        VStack(spacing: 12) {
            GroupBox("Bluetooth kapcsolat") {
                VStack(spacing: 8) {
                    HStack {
                        Button("BLE eszközök keresése") { ble.startScan() }.disabled(!ble.bluetoothReady || ble.isScanning)
                        Button("Keresés leállítása") { ble.stopScan() }.disabled(!ble.isScanning)
                        Spacer(); Button("Lista törlése") { ble.clearDevices() }
                    }
                    List(ble.devices) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name).font(.headline)
                                Text(device.id.uuidString).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(); Text("RSSI \(device.rssi)").font(.caption).foregroundStyle(.secondary)
                            Button(ble.connectedID == device.id ? "Csatlakozva" : "Csatlakozás") { ble.connect(to: device.peripheral) }
                                .disabled(ble.connectedID == device.id)
                        }
                    }.frame(height: 160)
                }.padding(4)
            }

            HStack(spacing: 12) {
                Button { ble.syncTime() } label: { Label("Idő szinkronizálása", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity).padding(7) }
                    .buttonStyle(.bordered).disabled(!ble.canSync)
                Button { ble.syncData() } label: { Label("Adatok szinkronizálása", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity).padding(7) }
                    .buttonStyle(.borderedProminent).disabled(!ble.canSync)
                Button(role: .destructive) { ble.disconnect() } label: { Label("Lecsatlakoztatás", systemImage: "link.badge.minus").padding(7) }
                    .disabled(ble.connectedID == nil)
            }

            HStack(spacing: 12) {
                card("Akkumulátor", ble.batteryLevel.map { "\($0)%" } ?? "–", "battery.75")
                card("Mai lépések", today.map { "\($0.steps)" } ?? "–", "figure.walk")
                card("Mai távolság", today.map { String(format: "%.2f km", ble.distanceKm(for: $0.steps)) } ?? "–", "location")
                card("Mai kalória", today.map { "\($0.calories) kcal" } ?? "–", "flame")
            }

            HStack {
                Text("Lépéshossz:").foregroundStyle(.secondary)
                TextField("50", value: $ble.strideLengthCm, format: .number.precision(.fractionLength(0))).frame(width: 60).textFieldStyle(.roundedBorder)
                Text("cm").foregroundStyle(.secondary)
                Spacer()
            }
            Spacer()
            status
        }.padding(.top, 8)
    }

    private var monthly: some View {
        VStack(spacing: 14) {
            HStack {
                Text(Date.now.formatted(.dateTime.year().month(.wide))).font(.title2.bold())
                Spacer()
                Picker("Mutató", selection: $metric) {
                    ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 430)
            }

            let days = monthDaysFilled
            HStack(spacing: 12) {
                card("Havi lépések", "\(days.reduce(0) { $0 + $1.steps })", "figure.walk")
                card("Havi távolság", String(format: "%.2f km", days.reduce(0.0) { $0 + ble.distanceKm(for: $1.steps) }), "location")
                card("Havi kalória", "\(days.reduce(0) { $0 + $1.calories }) kcal", "flame")
            }

            GroupBox {
                MonthlyBarChart(days: days, metric: metric, distanceProvider: ble.distanceKm(for:))
                    .frame(minHeight: 390)
                    .padding(12)
            }
            Text("A grafikon a Macen helyben eltárolt napi szinkronokból épül. A korábbi napokat az alkalmazás nem írja felül; csak a mai nap frissül új szinkronkor.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            status
        }.padding(.top, 8)
    }

    private var diagnostics: some View {
        VStack(spacing: 10) {
            HStack { Text("Bluetooth diagnosztika").font(.title2.bold()); Spacer(); Text("Mark 1 protokoll").foregroundStyle(.secondary) }
            ScrollView {
                Text(ble.diagnosticLog.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }.background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 8))
            status
        }.padding(.top, 8)
    }

    private var today: ActivityDay? {
        ble.activityDays.first { Calendar.current.isDateInToday($0.date) }
    }

    private var monthDaysFilled: [ActivityDay] {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month], from: now)
        guard let start = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: now) else { return [] }
        let map = Dictionary(uniqueKeysWithValues: ble.currentMonthDays.map { (cal.startOfDay(for: $0.date), $0) })
        return range.compactMap { day in
            guard let date = cal.date(byAdding: .day, value: day - 1, to: start) else { return nil }
            let key = cal.startOfDay(for: date)
            return map[key] ?? ActivityDay(date: key, steps: 0, calories: 0)
        }
    }

    private func card(_ title: String, _ value: String, _ icon: String) -> some View {
        GroupBox {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title2).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(value).font(.title3.bold()).monospacedDigit()
                }
                Spacer()
            }.padding(5)
        }.frame(maxWidth: .infinity)
    }

    private var status: some View {
        Text(ble.status).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.secondary).textSelection(.enabled)
    }
}

private struct MonthlyBarChart: View {
    let days: [ActivityDay]
    let metric: Metric
    let distanceProvider: (Int) -> Double

    private func value(_ d: ActivityDay) -> Double {
        switch metric {
        case .steps: return Double(d.steps)
        case .distance: return distanceProvider(d.steps)
        case .calories: return Double(d.calories)
        }
    }

    private var maxValue: Double { max(days.map(value).max() ?? 0, metric == .steps ? 1000 : 1) }

    var body: some View {
        GeometryReader { g in
            let plotHeight = max(g.size.height - 55, 1)
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(days) { d in
                        let v = value(d)
                        VStack(spacing: 4) {
                            Spacer(minLength: 0)
                            Text(v > 0 ? label(v) : "")
                                .font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
                            RoundedRectangle(cornerRadius: 3)
                                .fill(v > 0 ? Color.accentColor : Color.secondary.opacity(0.12))
                                .frame(width: 18, height: max(v > 0 ? 5 : 2, plotHeight * CGFloat(v / maxValue)))
                            Text("\(Calendar.current.component(.day, from: d.date))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }.frame(width: 30)
                    }
                }
                .frame(minWidth: g.size.width, minHeight: g.size.height, alignment: .bottomLeading)
                .padding(.horizontal, 8)
            }
        }
    }

    private func label(_ v: Double) -> String {
        switch metric {
        case .steps: return String(Int(v))
        case .distance: return String(format: "%.1f", v)
        case .calories: return String(Int(v))
        }
    }
}
