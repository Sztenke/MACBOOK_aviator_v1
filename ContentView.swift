import SwiftUI

private enum ActivityMetric: String, CaseIterable, Identifiable {
    case steps = "Lépés"
    case distance = "Távolság"
    case calories = "Kalória"
    var id: String { rawValue }
}
private enum ActivityRange: Int, CaseIterable, Identifiable {
    case week = 7, month = 30
    var id: Int { rawValue }
    var title: String { rawValue == 7 ? "7 nap" : "30 nap" }
}

struct ContentView: View {
    @StateObject private var ble = BLEManager()
    @State private var selectedTab = 0
    @State private var chartMetric: ActivityMetric = .steps
    @State private var chartRange: ActivityRange = .week

    var body: some View {
        VStack(spacing: 12) {
            header
            TabView(selection: $selectedTab) {
                overviewTab.tabItem { Label("Áttekintés", systemImage: "house") }.tag(0)
                activityTab.tabItem { Label("Aktivitás", systemImage: "figure.walk") }.tag(1)
                chartsTab.tabItem { Label("Grafikonok", systemImage: "chart.bar.xaxis") }.tag(2)
                alarmsTab.tabItem { Label("Ébresztések", systemImage: "alarm") }.tag(3)
                diagnosticsTab.tabItem { Label("Diagnosztika", systemImage: "waveform.path.ecg") }.tag(4)
            }
        }
        .padding(18).frame(minWidth: 900, minHeight: 720)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("AVIATOR Sync").font(.largeTitle.bold())
                Text("F-Series Mark 1 / AVW79215G360").foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(ble.connectedID != nil ? Color.green : (ble.bluetoothReady ? Color.green : Color.orange)).frame(width: 11, height: 11)
            Text(ble.connectedID != nil ? "AVIATOR csatlakoztatva" : (ble.bluetoothReady ? "Bluetooth kész" : "Bluetooth nem kész")).foregroundStyle(.secondary)
        }
    }

    private var overviewTab: some View {
        VStack(spacing: 14) {
            connectionBox
            HStack(spacing: 12) {
                Button { ble.syncTime() } label: { Label("Idő szinkronizálása", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity).padding(7) }
                    .buttonStyle(.bordered).controlSize(.large).disabled(!ble.canSync)
                Button { ble.syncData() } label: { Label(ble.isActivitySyncing ? "Adatok szinkronizálása…" : "Adatok szinkronizálása", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity).padding(7) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!ble.canSync || ble.isActivitySyncing)
                Button(role: .destructive) { ble.disconnect() } label: { Label("Lecsatlakoztatás", systemImage: "link.badge.minus").padding(7) }
                    .disabled(ble.connectedID == nil)
            }
            HStack(spacing: 12) {
                summaryCard(title: "Akkumulátor", value: ble.batteryLevel.map { "\($0)%" } ?? "–", icon: "battery.75")
                summaryCard(title: activityCardPrefix + " lépések", value: displayActivity.map { "\($0.steps)" } ?? "–", icon: "figure.walk")
                summaryCard(title: activityCardPrefix + " távolság", value: displayActivity.map { String(format: "%.2f km", ble.distanceKm(for: $0.steps)) } ?? "–", icon: "location")
                summaryCard(title: activityCardPrefix + " kalória", value: displayActivity.map { String(format: "%.1f kcal", Double($0.calories) / 1000.0) } ?? "–", icon: "flame")
            }
            HStack {
                Text("Lépéshossz:").foregroundStyle(.secondary)
                TextField("75", value: $ble.strideLengthCm, format: .number.precision(.fractionLength(0))).frame(width: 60).textFieldStyle(.roundedBorder)
                Text("cm").foregroundStyle(.secondary)
                Spacer(); Text("\(ble.totalStoredDays) nap eltárolva").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(); statusLine
        }.padding(.top, 8)
    }

    private var connectionBox: some View {
        GroupBox("Bluetooth kapcsolat") {
            VStack(spacing: 8) {
                HStack {
                    Button(ble.isScanning ? "Keresés folyamatban…" : "BLE eszközök keresése") { ble.startScan() }.disabled(!ble.bluetoothReady || ble.isScanning)
                    Button("Keresés leállítása") { ble.stopScan() }.disabled(!ble.isScanning)
                    Spacer(); Button("Lista törlése") { ble.clearDevices() }.disabled(ble.devices.isEmpty)
                }
                List(ble.devices) { device in
                    HStack {
                        VStack(alignment: .leading) { Text(device.name).font(.headline); Text(device.id.uuidString).font(.caption2).foregroundStyle(.secondary) }
                        Spacer(); Text("RSSI \(device.rssi)").font(.caption).foregroundStyle(.secondary)
                        Button(ble.connectedID == device.id ? "Csatlakozva" : "Csatlakozás") { ble.connect(to: device.peripheral) }.disabled(ble.connectedID == device.id)
                    }.padding(.vertical, 2)
                }.frame(height: 160)
            }.padding(4)
        }
    }

    private var activityTab: some View {
        VStack(spacing: 12) {
            HStack { Text("Aktivitási előzmények").font(.title2.bold()); Spacer(); Text("\(ble.totalStoredDays) nap").foregroundStyle(.secondary) }
            GroupBox {
                if ble.activityDays.isEmpty { Text("Még nincs letöltött aktivitási adat.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding() }
                else { List(ble.activityDays) { day in HStack { Text(day.date.formatted(date: .numeric, time: .omitted)).frame(maxWidth: .infinity, alignment: .leading); Text("\(day.steps)").frame(width: 100, alignment: .trailing); Text(String(format: "%.2f km", ble.distanceKm(for: day.steps))).frame(width: 110, alignment: .trailing); Text(String(format: "%.1f kcal", Double(day.calories) / 1000.0)).frame(width: 100, alignment: .trailing) } } }
            }
            statusLine
        }.padding(.top, 8)
    }

    private var chartsTab: some View {
        VStack(spacing: 14) {
            HStack { Text("Aktivitási grafikon").font(.title2.bold()); Spacer(); Picker("Időtáv", selection: $chartRange) { ForEach(ActivityRange.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).frame(width: 180) }
            HStack { Picker("Mutató", selection: $chartMetric) { ForEach(ActivityMetric.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 430); Spacer() }
            let days = chartDays
            HStack(spacing: 12) {
                summaryCard(title: "Összes lépés", value: "\(days.reduce(0){$0+$1.steps})", icon: "figure.walk")
                summaryCard(title: "Összes távolság", value: String(format: "%.2f km", days.reduce(0.0){$0+ble.distanceKm(for:$1.steps)}), icon: "location")
                summaryCard(title: "Összes kalória", value: String(format: "%.1f kcal", Double(days.reduce(0){$0+$1.calories}) / 1000.0), icon: "flame")
            }
            GroupBox { PrettyBarChart(days: filledChartDays, metric: chartMetric, distanceProvider: ble.distanceKm(for:)).frame(minHeight: 360).padding(12) }
            statusLine
        }.padding(.top, 8)
    }

    private var alarmsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ébresztések").font(.title2.bold())
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Mark 1 ébresztés-kezelés", systemImage: "alarm.fill").font(.headline)
                    Text("Az eredeti Mark 1 alkalmazás ébresztés/emlékeztető funkciója azonosítva van. Az órára írást ebben a buildben még nem engedélyeztem, amíg a teljes parancscsomag bájtsorrendjét nem validáltuk a Mark 1 firmware-rel.").foregroundStyle(.secondary)
                    Text("Ez megakadályozza, hogy hibás emlékeztető-adat kerüljön az órára.").font(.caption).foregroundStyle(.secondary)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(); statusLine
        }.padding(.top, 8)
    }

    private var diagnosticsTab: some View {
        VStack(spacing: 12) { HStack { Text("Bluetooth diagnosztika").font(.title2.bold()); Spacer(); Text("Mark 1 protokoll").foregroundStyle(.secondary) }; ScrollView { Text(ble.diagnosticLog.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }.background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 8)); statusLine }.padding(.top, 8)
    }

    private func summaryCard(title: String, value: String, icon: String) -> some View {
        GroupBox { HStack(spacing: 10) { Image(systemName: icon).font(.title2).frame(width: 28); VStack(alignment: .leading, spacing: 2) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title3.bold()).monospacedDigit() }; Spacer() }.padding(5) }.frame(maxWidth: .infinity)
    }
    private var statusLine: some View { Text(ble.status).frame(maxWidth: .infinity, alignment: .leading).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
    private var todayActivity: ActivityDay? { ble.activityDays.first { Calendar.current.isDateInToday($0.date) } }
    private var displayActivity: ActivityDay? { todayActivity ?? ble.activityDays.first }
    private var activityCardPrefix: String { todayActivity != nil ? "Mai" : "Legutóbbi" }

    // A Mark 1 régi, az órában tárolt rekordokat is visszaad. Ha nincs aktuális dátumú
    // rekord, a grafikon akkor is a legutóbbi 7/30 eltárolt napot mutatja, nem üres mezőt.
    private var chartDays: [ActivityDay] {
        Array(ble.activityDays.prefix(chartRange.rawValue)).sorted { $0.date < $1.date }
    }
    private var filledChartDays: [ActivityDay] { chartDays }
}

private struct PrettyBarChart: View {
    let days:[ActivityDay]; let metric:ActivityMetric; let distanceProvider:(Int)->Double
    private func val(_ d:ActivityDay)->Double { switch metric { case .steps:return Double(d.steps); case .distance:return distanceProvider(d.steps); case .calories:return Double(d.calories) / 1000.0 } }
    private var maxV:Double { max(days.map(val).max() ?? 0, metric == .steps ? 1000 : 1) }
    private func text(_ v:Double)->String { switch metric { case .steps:return String(Int(v)); case .distance:return String(format:"%.2f",v); case .calories:return String(format:"%.1f",v) } }
    var body: some View {
        GeometryReader { g in
            let dense=days.count>10, barW:CGFloat=dense ? 14 : 54, plotH=max(g.size.height-55,1)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment:.bottom, spacing:dense ? 10 : 28) {
                    ForEach(days) { d in
                        let v=val(d)
                        VStack(spacing:5) {
                            Spacer(minLength:0)
                            Text(v > 0 ? text(v) : "").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            RoundedRectangle(cornerRadius:dense ? 3 : 7)
                                .fill(v > 0 ? Color.accentColor : Color.secondary.opacity(0.12))
                                .frame(width:barW,height:max(v > 0 ? 5 : 2, plotH*CGFloat(v/maxV)))
                            Text(d.date.formatted(.dateTime.day().month(.abbreviated))).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(width:max(barW, dense ? 28 : 62))
                    }
                }.frame(minWidth:g.size.width, minHeight:g.size.height, alignment:.bottomLeading).padding(.horizontal,8)
            }
        }
    }
}
