import SwiftUI

struct ContentView: View {
    @EnvironmentObject var workout: WorkoutManager
    @EnvironmentObject var motion: MotionRecorder

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(workout.heartRate.map { String(Int($0.rounded())) } ?? "--")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.red)
                    Text("bpm").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    if let at = workout.heartRateAt {
                        Text(age(at)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spark(values: workout.hrHistory, color: .red)
                HStack {
                    Text(String(format: "|a| %.2f g", motion.accelMag)).font(.footnote)
                    Spacer()
                    Text(String(format: "|ω| %.0f °/s", motion.gyroMag)).font(.footnote)
                }
                Spark(values: motion.accelHistory, color: .green)
                Spark(values: motion.gyroHistory, color: .cyan)
                Text(String(format: "%@ · %.0f Hz · %d samples · HR %d", motion.mode, motion.rateHz, motion.samples, workout.hrSamples))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let s = workout.startedAt, workout.running {
                    Text(elapsed(s)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Button(workout.running ? "Stop & send to iPhone" : "Start") {
                    if workout.running {
                        let files = motion.stop()
                        workout.stop(motionFiles: files)
                    } else {
                        motion.start()
                        workout.start(motionFiles: { motion.recordedFiles })
                    }
                }
                .tint(workout.running ? .red : .green)
                .buttonStyle(.borderedProminent)
                if !workout.running {
                    Toggle("800 Hz accel (S8+/Ultra)", isOn: $motion.want800HzAccel).font(.footnote)
                    if !workout.pendingFiles().isEmpty {
                        Button("Resend \(workout.pendingFiles().count) file(s)") { workout.transfer(workout.pendingFiles()) }
                            .font(.footnote)
                    }
                }
                Text(workout.status).font(.system(size: 11)).foregroundStyle(.secondary)
                if !workout.lastTransfer.isEmpty {
                    Text(workout.lastTransfer).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { workout.requestAuthorization() }
    }

    private func age(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        return s < 2 ? "now" : "\(s)s ago"
    }
    private func elapsed(_ s: Date) -> String {
        let t = Int(Date().timeIntervalSince(s))
        return String(format: "%02d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60)
    }
}

struct Spark: View {
    let values: [Double]
    let color: Color
    var body: some View {
        GeometryReader { geo in
            Path { p in
                guard values.count > 1 else { return }
                let lo = values.min()!, hi = max(values.max()!, lo + 1e-6)
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let y = geo.size.height * (1 - CGFloat((v - lo) / (hi - lo)))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, lineWidth: 1.5)
        }
        .frame(height: 22)
    }
}
