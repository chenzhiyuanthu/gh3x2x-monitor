import SwiftUI

struct HealthMonitorView: View {
    @EnvironmentObject var store: VitalsStore
    @EnvironmentObject var evk: EVKManager
    @EnvironmentObject var imu: IMUManager
    @State private var showDevices = false
    @State private var reportURL: URL?
    @State private var preparingReport = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.backgroundTop, Theme.backgroundBottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    header
                    statusRow
                        .padding(.top, 14)
                    heartRateSection
                        .padding(.top, 26)
                    metricGrid
                        .padding(.top, 22)
                    shareSection
                        .padding(.top, 34)
                    Spacer(minLength: 110)
                }
                .padding(.horizontal, 15)
            }

            floatingButton
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showDevices) { DeviceSheet() }
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            Text("HEALTH MONITOR")
                .font(.system(size: 15, weight: .bold))
                .tracking(2.6)
                .foregroundStyle(Theme.textPrimary)
            HStack {
                Button { showDevices = true } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 44, height: 44, alignment: .leading)
                }
                Spacer()
            }
        }
        .padding(.top, 8)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Button { showDevices = true } label: {
                HStack(spacing: 6) {
                    Circle().fill(connectionColor).frame(width: 7, height: 7)
                    Text(connectionText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.06), in: Capsule())
            }
            HStack(spacing: 6) {
                Image(systemName: store.wear.isWorn ? "hand.raised.fill" : "hand.raised.slash")
                    .font(.system(size: 11, weight: .bold))
                Text(store.wear.label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(store.wear.isWorn ? Theme.green : (store.wear == .unknown ? Theme.textSecondary : Theme.amber))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.06), in: Capsule())
            HStack(spacing: 6) {
                Image(systemName: motionIcon)
                    .font(.system(size: 11, weight: .bold))
                Text(store.imuAvailable ? store.motionState.label : "IMU —")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(motionColor)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.06), in: Capsule())
            Spacer()
        }
    }

    private var motionIcon: String {
        guard store.imuAvailable else { return "gyroscope" }
        switch store.motionState {
        case .active: return "figure.run"
        case .light: return "figure.walk"
        default: return "figure.stand"
        }
    }
    private var motionColor: Color {
        guard store.imuAvailable else { return Theme.textTertiary }
        switch store.motionState {
        case .active: return Theme.amber
        case .light: return Theme.textPrimary
        default: return Theme.green
        }
    }

    private var connectionColor: Color {
        switch evk.state {
        case .streaming: return Theme.green
        case .connecting, .configuring, .scanning: return Theme.amber
        default: return Theme.red
        }
    }
    private var connectionText: String {
        switch evk.state {
        case .streaming(let n): return n + (evk.rssi.map { " · \($0) dBm" } ?? "")
        default: return evk.state.label
        }
    }

    // MARK: - Heart rate

    private var heartRateSection: some View {
        ZStack(alignment: .topLeading) {
            GridBackground()
                .padding(.horizontal, -15)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(text: "Heart rate")
                    Image(systemName: "heart.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.blue)
                        .padding(.top, 14)
                    Text(store.heartRate.map(String.init) ?? "--")
                        .font(Theme.value(46))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.top, 6)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.3), value: store.heartRate)
                    Text("BPM")
                        .font(Theme.label(14))
                        .tracking(2)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.top, 2)
                    Text("Zone \(store.zone)")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 14)
                    ZoneBar(zone: store.zone)
                        .padding(.top, 10)
                    if store.motionAffected, store.heartRate != nil {
                        Text("motion · reading may lag")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.amber)
                            .padding(.top, 8)
                    } else if store.heartRateSource == .waveform, let algo = store.sensorHeartRate {
                        Text("from PPG · sensor \(algo)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.amber)
                            .padding(.top, 8)
                    } else if store.heartRateSource == .waveform {
                        Text("from PPG waveform")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.amber)
                            .padding(.top, 8)
                    } else if store.heartRate == nil {
                        Text(hrHint)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 8)
                    }
                }
                .frame(width: 112, alignment: .leading)
                HeartRateChart(points: store.hrHistory, window: 5 * 60, live: evk.state.isStreaming)
                    .frame(height: 124)
                    .padding(.top, 40)
                    .padding(.leading, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }

    private var hrHint: String {
        switch store.wear {
        case .noContact: return "Place sensor on skin"
        case .offWrist, .notLiving: return "Sensor not on wrist"
        default: return evk.state.isStreaming ? "Measuring…" : ""
        }
    }

    // MARK: - Metric grid

    private var metricGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            MetricCard(icon: "lungs", title: "Respiratory rate",
                       value: store.respiratoryRate.map { String(format: "%.1f", $0) } ?? "--", unit: "rpm") {
                RangePill.make(value: store.respiratoryRate, range: store.respiratoryRange, pendingText: "collecting…")
            }
            MetricCard(icon: "drop", title: "Blood oxygen (SpO₂)",
                       value: store.spo2.map(String.init) ?? "--", unit: "%") {
                RangePill.make(value: store.spo2.map(Double.init), range: store.spo2Range, pendingText: "measuring…")
            }
            MetricCard(icon: "arrow.down.heart", title: "RHR",
                       value: store.restingHeartRate.map(String.init) ?? "--", unit: "bpm") {
                RangePill.make(value: store.restingHeartRate.map(Double.init), range: store.rhrRange, pendingText: "needs 1 min")
            }
            MetricCard(icon: "waveform.path.ecg", title: "HRV",
                       value: store.hrv.map { String(Int($0.rounded())) } ?? "--", unit: "ms") {
                RangePill.make(value: store.hrv, range: store.hrvRange, pendingText: "collecting…")
            }
            MetricCard(icon: "thermometer.medium", title: "Skin temp (from baseline)",
                       value: store.skinTempDelta.map { String(format: "%+.1f", $0) } ?? "--", unit: "°C") {
                if store.skinTempDelta == nil {
                    RangePill(status: .pending, text: "no temp sensor")
                } else {
                    RangePill.make(value: store.skinTempDelta, range: store.tempRange)
                }
            }
            Color.clear.frame(height: 0)
        }
    }

    // MARK: - Share

    private var shareSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if let url = reportURL {
                    ShareLink(item: url) { shareLabel }
                } else {
                    Button { prepareReport() } label: { shareLabel }
                }
            }
            .buttonStyle(.plain)
            Text("Printable report for sharing with your doctor, physician, trainer, or anyone of your choosing.")
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(3)
        }
    }

    private var shareLabel: some View {
        HStack(spacing: 22) {
            if preparingReport {
                ProgressView().tint(Theme.textPrimary).frame(width: 24)
            } else {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24)
            }
            Text("SHARE YOUR HEALTH REPORT")
                .font(.system(size: 15, weight: .bold))
                .tracking(2)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(height: 50)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func prepareReport() {
        preparingReport = true
        Task { @MainActor in
            reportURL = HealthReport.makePDF(store: store, device: evk)
            preparingReport = false
        }
    }

    // MARK: - Floating button

    private var floatingButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    if evk.state.isStreaming { showDevices = true } else { evk.reconnect() }
                } label: {
                    ZStack {
                        Circle().fill(Theme.card)
                        Circle().stroke(Theme.blue.opacity(0.8), lineWidth: 1.5).padding(9)
                        Image(systemName: evk.state.isStreaming ? "waveform.path.ecg" : "arrow.clockwise")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .frame(width: 58, height: 58)
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 18)
            }
        }
    }
}
