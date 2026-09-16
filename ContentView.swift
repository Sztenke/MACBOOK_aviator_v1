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
    @State private var shownMonth = Date()
    @State private var calibrationCalories = 178.0

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
        .frame(minWidth: 940, minHeight: 720)
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
                    }.frame(height: 150)
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
                card("Akkumulátor", ble.batteryLevel.map { "\($0)%" } ?? "–", batteryIcon)
                card("Mai lépések", today.map { "\($0.steps)" } ?? "–", "figure.walk")
                card("Mai távolság", today.map { String(format: "%.2f km", ble.distanceKm(for: $0.steps)) } ?? "–", "location")
                card("Mai kalória", today.map { "\(ble.calories(for: $0.steps)) kcal" } ?? "–", "flame")
            }

            GroupBox("Kalória kalibrálása") {
                HStack(spacing: 12) {
                    Text("Az órán most:").foregroundStyle(.secondary)
                    TextField("96", value: $calibrationCalories, format: .number.precision(.fractionLength(0)))
                        .frame(width: 80).textFieldStyle(.roundedBorder)
                    Text("kcal")
                    Button("Kalória kalibrálása") {
                        _ = ble.calibrateCalories(calibrationCalories)
                    }
                    .disabled(today == nil)
                    Spacer()
                }
                .padding(4)
            }

            Text("A távolság automatikusan számolódik 0,726 m/lépés alapján, így ehhez már nem kell kézi kalibrálás. A kcal egyelőre külön kalibrálható, amíg a Mark 1 eredeti kalóriaszámítását pontosan vissza nem fejtjük.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            status
        }.padding(.top, 8)
    }

    private var monthly: some View {
        let days = monthDaysFilled
        return VStack(spacing: 14) {
            HStack {
                Button { shownMonth = Calendar.current.date(byAdding: .month, value: -1, to: shownMonth) ?? shownMonth } label: {
                    Image(systemName: "chevron.left")
                }
                Text(shownMonth.formatted(.dateTime.year().month(.wide))).font(.title2.bold()).frame(minWidth: 190)
                Button { shownMonth = Calendar.current.date(byAdding: .month, value: 1, to: shownMonth) ?? shownMonth } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(Calendar.current.compare(shownMonth, to: Date(), toGranularity: .month) != .orderedAscending)
                Spacer()
                Picker("Mutató", selection: $metric) {
                    ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 430)
            }

            HStack(spacing: 12) {
                card("Havi lépések", "\(days.reduce(0) { $0 + $1.steps })", "figure.walk")
                card("Havi távolság", String(format: "%.2f km", days.reduce(0.0) { $0 + ble.distanceKm(for: $1.steps) }), "location")
                card("Havi kalória", "\(days.reduce(0) { $0 + ble.calories(for: $1.steps) }) kcal", "flame")
            }

            GroupBox {
                MonthlyBarChart(days: days, metric: metric,
                                distanceProvider: ble.distanceKm(for:),
                                calorieProvider: ble.calories(for:))
                    .frame(minHeight: 420)
                    .padding(12)
            }
            Text("Napi oszlopok a kiválasztott hónaphoz. A korábbi napok adatai megmaradnak; szinkronkor csak a mai nap frissül.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            status
        }.padding(.top, 8)
    }

    private var diagnostics: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Bluetooth diagnosztika").font(.title2.bold())
                Spacer()
                if let raw = ble.batteryRaw { Text("Akku raw: \(raw)").foregroundStyle(.secondary) }
                Text("Mark 1 protokoll").foregroundStyle(.secondary)
            }
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


    private var batteryIcon: String {
        guard let level = ble.batteryLevel else { return "battery.0" }
        switch level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    private var today: ActivityDay? {
        ble.activityDays.first { Calendar.current.isDateInToday($0.date) }
    }

    private var monthDaysFilled: [ActivityDay] {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: shownMonth)
        guard let start = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: start) else { return [] }
        let data = ble.days(in: shownMonth)
        let map = Dictionary(uniqueKeysWithValues: data.map { (cal.startOfDay(for: $0.date), $0) })
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
    let calorieProvider: (Int) -> Int

    private func value(_ d: ActivityDay) -> Double {
        switch metric {
        case .steps: return Double(d.steps)
        case .distance: return distanceProvider(d.steps)
        case .calories: return Double(calorieProvider(d.steps))
        }
    }

    private var maxValue: Double {
        let m = days.map(value).max() ?? 0
        return max(m * 1.15, metric == .steps ? 1000 : 1)
    }

    var body: some View {
        GeometryReader { g in
            let plotHeight = max(g.size.height - 55, 1)
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(axisLabel(maxValue)).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(axisLabel(maxValue / 2)).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("0").font(.caption2).foregroundStyle(.secondary)
                    Spacer().frame(height: 18)
                }.frame(width: 48)

                ScrollView(.horizontal, showsIndicators: true) {
                    ZStack(alignment: .bottomLeading) {
                        VStack(spacing: 0) {
                            Divider(); Spacer(); Divider(); Spacer(); Divider()
                        }
                        .frame(height: plotHeight)

                        HStack(alignment: .bottom, spacing: 7) {
                            ForEach(days) { d in
                                let v = value(d)
                                VStack(spacing: 4) {
                                    Spacer(minLength: 0)
                                    Text(v > 0 ? label(v) : "")
                                        .font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(v > 0 ? Color.accentColor : Color.secondary.opacity(0.10))
                                        .frame(width: 20, height: max(v > 0 ? 6 : 2, plotHeight * CGFloat(v / maxValue)))
                                    Text("\(Calendar.current.component(.day, from: d.date))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }.frame(width: 31)
                            }
                        }
                        .frame(minHeight: plotHeight + 25, alignment: .bottom)
                    }
                    .frame(minWidth: max(g.size.width - 60, CGFloat(days.count) * 38), minHeight: g.size.height, alignment: .bottomLeading)
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    private func axisLabel(_ v: Double) -> String {
        switch metric {
        case .steps: return String(Int(v.rounded()))
        case .distance: return String(format: "%.1f", v)
        case .calories: return String(Int(v.rounded()))
        }
    }

    private func label(_ v: Double) -> String {
        switch metric {
        case .steps: return String(Int(v))
        case .distance: return String(format: "%.2f", v)
        case .calories: return String(Int(v))
        }
    }
}
