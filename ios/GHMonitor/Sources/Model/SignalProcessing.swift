import Foundation

/// Lightweight DSP on the raw PPG stream (25 Hz) — independent of the sensor's on-board algorithms.
enum SignalProcessing {
    /// Detrend with a moving average of `window` samples and return the AC component.
    static func detrend(_ x: [Double], window: Int) -> [Double] {
        let n = x.count
        guard n > window * 2 else { return x.map { _ in 0 } }
        var out = [Double](repeating: 0, count: n)
        var sum = 0.0
        var count = 0
        // centered moving average via prefix sums
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + x[i] }
        for i in 0..<n {
            let lo = max(0, i - window), hi = min(n - 1, i + window)
            sum = prefix[hi + 1] - prefix[lo]
            count = hi - lo + 1
            out[i] = x[i] - sum / Double(count)
        }
        return out
    }

    /// Dominant frequency in [fLow, fHigh] Hz by direct DFT. Returns (Hz, share of energy in the peak bin).
    static func dominantFrequency(_ s: [Double], fs: Double, fLow: Double, fHigh: Double, step: Double) -> (Double, Double)? {
        let n = s.count
        guard n > 8 else { return nil }
        let mean = s.reduce(0, +) / Double(n)
        let z = s.map { $0 - mean }
        var bestF = 0.0, bestP = 0.0, total = 0.0
        var f = fLow
        while f <= fHigh + 1e-9 {
            var re = 0.0, im = 0.0
            let w = 2 * Double.pi * f / fs
            for k in 0..<n {
                let a = w * Double(k)
                re += z[k] * cos(a)
                im -= z[k] * sin(a)
            }
            let p = re * re + im * im
            total += p
            if p > bestP { bestP = p; bestF = f }
            f += step
        }
        guard total > 0 else { return nil }
        return (bestF, bestP / total)
    }

    /// Power spectrum on a frequency grid (direct DFT; the signals are short).
    static func spectrum(_ s: [Double], fs: Double, fLow: Double, fHigh: Double, step: Double) -> [(f: Double, p: Double)] {
        let n = s.count
        guard n > 8 else { return [] }
        let mean = s.reduce(0, +) / Double(n)
        let z = s.map { $0 - mean }
        var out: [(Double, Double)] = []
        var f = fLow
        while f <= fHigh + 1e-9 {
            var re = 0.0, im = 0.0
            let w = 2 * Double.pi * f / fs
            for k in 0..<n {
                let a = w * Double(k)
                re += z[k] * cos(a)
                im -= z[k] * sin(a)
            }
            out.append((f, re * re + im * im))
            f += step
        }
        return out
    }

    /// Pulse rate from ~10 s of raw PPG. Returns (bpm, quality 0…1, AC peak-to-peak).
    /// When accelerometer magnitude (same 10 s window, `accFs`) and a motion weight (0…1) are given,
    /// PPG spectral bins that coincide with motion frequencies are suppressed (motion-artifact rejection).
    static func pulseRate(ppg: [Double], fs: Double = 25, acc: [Double]? = nil, accFs: Double = 50, motionWeight: Double = 0)
        -> (bpm: Int, quality: Double, peakToPeak: Double)? {
        let x = Array(ppg.suffix(Int(fs * 10)))
        guard x.count >= Int(fs * 5) else { return nil }
        var ac = detrend(x, window: 20)
        ac = (1..<(ac.count - 1)).map { (ac[$0 - 1] + ac[$0] + ac[$0 + 1]) / 3 }
        let spec = spectrum(ac, fs: fs, fLow: 0.6, fHigh: 3.0, step: 0.02)
        guard !spec.isEmpty else { return nil }
        let total = spec.reduce(0) { $0 + $1.p }
        guard total > 0 else { return nil }
        let maxP = spec.map(\.p).max() ?? 1
        var scores = spec.map { $0.p / maxP }
        if let a = acc, motionWeight > 0.02 {
            let am = Array(a.suffix(Int(accFs * 10)))
            if am.count >= Int(accFs * 4) {
                let aspec = spectrum(detrend(am, window: Int(accFs)), fs: accFs, fLow: 0.6, fHigh: 3.0, step: 0.02)
                let aMax = aspec.map(\.p).max() ?? 0
                if aMax > 0, aspec.count == spec.count {
                    for i in 0..<scores.count {
                        // suppress PPG energy where the arm is moving at the same frequency (and at its 2nd harmonic)
                        var penalty = aspec[i].p / aMax
                        if i >= 1, 2 * i < aspec.count { penalty = max(penalty, 0.6 * aspec[i / 2].p / aMax) }
                        scores[i] -= min(1, motionWeight) * 0.9 * penalty
                    }
                }
            }
        }
        guard let bestIdx = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return nil }
        var f = spec[bestIdx].f
        // peakiness of the (motion-corrected) spectrum: fraction of positive score in the best bin
        let pos = scores.map { max(0, $0) }
        let sumPos = pos.reduce(0, +)
        var share = sumPos > 0 ? pos[bestIdx] / sumPos : spec[bestIdx].p / total
        if motionWeight > 0.02 { share *= max(0.4, 1 - 0.4 * min(1, motionWeight)) }
        // Harmonic guard: a strong dicrotic notch can make the 2nd harmonic win. If the sub-harmonic (f/2)
        // still carries at least half the peak power, it is the fundamental.
        if f / 2 >= 0.6 {
            let pPeak = power(ac, fs: fs, at: f)
            let pHalf = max(power(ac, fs: fs, at: f / 2), power(ac, fs: fs, at: f / 2 - 0.02), power(ac, fs: fs, at: f / 2 + 0.02))
            if pPeak > 0, pHalf / pPeak >= 0.5 { f /= 2; share *= pHalf / pPeak }
        }
        let pp = (ac.max() ?? 0) - (ac.min() ?? 0)
        return (Int((f * 60).rounded()), min(1, share * 8), pp)
    }

    static func power(_ s: [Double], fs: Double, at f: Double) -> Double {
        let n = s.count
        let mean = s.reduce(0, +) / Double(max(n, 1))
        var re = 0.0, im = 0.0
        let w = 2 * Double.pi * f / fs
        for k in 0..<n {
            let a = w * Double(k)
            re += (s[k] - mean) * cos(a)
            im -= (s[k] - mean) * sin(a)
        }
        return re * re + im * im
    }

    /// Respiratory rate from ~60 s of raw PPG: the baseline wander (0.1–0.5 Hz) modulated by breathing.
    static func respiratoryRate(ppg: [Double], fs: Double = 25) -> (rpm: Double, quality: Double)? {
        let x = Array(ppg.suffix(Int(fs * 60)))
        guard x.count >= Int(fs * 40) else { return nil }
        // Baseline: moving average over ~1 s removes the pulse, leaving the respiratory modulation.
        let n = x.count
        var base = [Double](repeating: 0, count: n)
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + x[i] }
        for i in 0..<n {
            let lo = max(0, i - 12), hi = min(n - 1, i + 12)
            base[i] = (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
        }
        // Remove slow drift (> 10 s) so AGC steps don't dominate.
        let slow = detrend(base, window: 125)
        // Decimate to 5 Hz for speed.
        let dec = stride(from: 0, to: slow.count, by: 5).map { slow[$0] }
        guard let (f, share) = dominantFrequency(dec, fs: fs / 5, fLow: 0.1, fHigh: 0.5, step: 0.005) else { return nil }
        return (f * 60, min(1, share * 6))
    }

    /// Motion level from accelerometer magnitude (g) over the window: std in mg.
    static func motionLevel(magnitude: [Double]) -> Double {
        guard magnitude.count >= 10 else { return 0 }
        let m = magnitude.reduce(0, +) / Double(magnitude.count)
        let v = magnitude.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(magnitude.count)
        return v.squareRoot() * 1000
    }

    /// RMSSD (ms) using only pairs of RR intervals that were adjacent beats (seq differs by 1), so gaps left by
    /// rejected intervals do not create fake successive differences.
    static func rmssdAdjacent(_ rri: [(seq: Int, ms: Double)]) -> Double? {
        var acc = 0.0, n = 0
        for i in 1..<max(rri.count, 1) where rri[i].seq == rri[i - 1].seq + 1 {
            let d = rri[i].ms - rri[i - 1].ms
            acc += d * d; n += 1
        }
        guard n >= 10 else { return nil }
        return (acc / Double(n)).squareRoot()
    }

    /// RMSSD (ms) of successive RR intervals.
    static func rmssd(_ rri: [Double]) -> Double? {
        guard rri.count >= 4 else { return nil }
        var acc = 0.0
        for i in 1..<rri.count { let d = rri[i] - rri[i - 1]; acc += d * d }
        return (acc / Double(rri.count - 1)).squareRoot()
    }
}
