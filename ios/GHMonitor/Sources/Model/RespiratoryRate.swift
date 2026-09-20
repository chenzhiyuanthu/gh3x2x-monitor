import Foundation

/// Respiratory rate from the PPG, following the published pipeline
/// (Karlen et al. 2013 "Multiparameter respiratory rate estimation from the photoplethysmogram", IEEE TBME;
///  Charlton et al. 2016 "An assessment of algorithms to estimate respiratory rate from the ECG and PPG", Physiol Meas;
///  Charlton et al. 2018 review, IEEE Rev Biomed Eng):
///  1. band-pass the PPG (0.5–5 Hz) and detect beats (sub-sample peak timing, since the sensor only samples at 25 Hz);
///  2. per beat, the three respiratory-induced variations: RIFV (beat interval, respiratory sinus arrhythmia),
///     RIAV (pulse amplitude), RIIV (baseline intensity at the trough);
///  3. resample each at 4 Hz, band-pass to the breathing band 0.1–0.6 Hz (6–36 breaths/min);
///  4. estimate a rate per modality with the time-domain "count-orig" method (Schäfer & Kratky 2008), which Charlton's
///     assessment found more reliable than spectral peaks — a spectral peak on wrist PPG is easily captured by the
///     0.1 Hz Mayer / vasomotor waves and reports ~6 breaths/min regardless of breathing;
///  5. Smart Fusion: output the mean only when the modalities agree (SD ≤ 4 breaths/min), otherwise nothing.
///  A window is skipped when the beats are irregular (motion or misdetection).
enum RespiratoryRate {
    struct Estimate {
        let rpm: Double
        let rifv: Double?, riav: Double?, riiv: Double?
        let spread: Double        // SD of the fused modalities (breaths/min)
        let beats: Int
    }

    // MARK: - Filters (2nd-order Butterworth biquads via bilinear transform, applied forward and backward)
    private struct Biquad { let b0, b1, b2, a1, a2: Double }
    private static func butter2(_ fc: Double, fs: Double, low: Bool) -> Biquad {
        let w = tan(.pi * fc / fs), k = w * w, s2 = 2.0.squareRoot() * w, a0 = 1 + s2 + k
        let a1 = (2 * k - 2) / a0, a2 = (1 - s2 + k) / a0
        return low ? Biquad(b0: k / a0, b1: 2 * k / a0, b2: k / a0, a1: a1, a2: a2)
                   : Biquad(b0: 1 / a0, b1: -2 / a0, b2: 1 / a0, a1: a1, a2: a2)
    }
    private static func run(_ f: Biquad, _ x: [Double]) -> [Double] {
        var y = [Double](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<x.count {
            let v = x[i]
            let o = f.b0 * v + f.b1 * x1 + f.b2 * x2 - f.a1 * y1 - f.a2 * y2
            x2 = x1; x1 = v; y2 = y1; y1 = o; y[i] = o
        }
        return y
    }
    /// Zero-phase filtering with reflected padding (like scipy.signal.filtfilt).
    private static func filtfilt(_ f: Biquad, _ x: [Double], pad: Int) -> [Double] {
        guard x.count > 3 else { return x }
        let p = min(pad, x.count - 1)
        var xe: [Double] = []
        xe.reserveCapacity(x.count + 2 * p)
        for i in stride(from: p, through: 1, by: -1) { xe.append(2 * x[0] - x[i]) }
        xe.append(contentsOf: x)
        for i in 1...p { xe.append(2 * x[x.count - 1] - x[x.count - 1 - i]) }
        var y = run(f, xe)
        y.reverse(); y = run(f, y); y.reverse()
        return Array(y[p..<(p + x.count)])
    }
    static func bandpass(_ x: [Double], low: Double, high: Double, fs: Double) -> [Double] {
        let pad = Int(fs * 5)
        let hp = filtfilt(butter2(low, fs: fs, low: false), x, pad: pad)
        return filtfilt(butter2(high, fs: fs, low: true), hp, pad: pad)
    }

    // MARK: - Beats
    private static func peaks(_ p: [Double], refractory: Int) -> [Int] {
        var out: [Int] = []
        guard p.count > 2 else { return out }
        for i in 1..<(p.count - 1) where p[i] > p[i - 1] && p[i] >= p[i + 1] && p[i] > 0 {
            if let last = out.last, i - last < refractory {
                if p[i] > p[last] { out[out.count - 1] = i }
            } else {
                out.append(i)
            }
        }
        return out
    }
    /// Parabolic interpolation of the peak position (sub-sample timing matters at 25 Hz: one sample is 40 ms).
    private static func refine(_ p: [Double], _ i: Int) -> Double {
        guard i > 0, i < p.count - 1 else { return Double(i) }
        let y0 = p[i - 1], y1 = p[i], y2 = p[i + 1]
        let den = y0 - 2 * y1 + y2
        guard den != 0 else { return Double(i) }
        return Double(i) + max(-0.5, min(0.5, (y0 - y2) / (2 * den)))
    }

    // MARK: - Rate per modality
    private static func resample(_ t: [Double], _ v: [Double], from t0: Double, to t1: Double, fs: Double) -> [Double] {
        var out: [Double] = []
        var j = 0
        var x = t0
        while x < t1 {
            while j + 1 < t.count - 1 && t[j + 1] < x { j += 1 }
            let a = t[j], b = t[min(j + 1, t.count - 1)]
            let va = v[j], vb = v[min(j + 1, v.count - 1)]
            out.append(b > a ? va + (vb - va) * max(0, min(1, (x - a) / (b - a))) : va)
            x += 1 / fs
        }
        return out
    }
    /// Count-orig (Schäfer & Kratky): count the local maxima whose rise from the preceding minimum exceeds 0.2 × Q3
    /// of all such rises, and take the mean spacing between them.
    static func countOrig(_ y: [Double], fs: Double) -> Double? {
        guard y.count > 8 else { return nil }
        let m = y.reduce(0, +) / Double(y.count)
        let z = y.map { $0 - m }
        var maxima: [Int] = [], minima: [Int] = []
        for i in 1..<(z.count - 1) {
            if z[i] > z[i - 1] && z[i] >= z[i + 1] { maxima.append(i) }
            if z[i] < z[i - 1] && z[i] <= z[i + 1] { minima.append(i) }
        }
        guard maxima.count >= 2, !minima.isEmpty else { return nil }
        var rises: [Double] = []
        var k = 0
        for i in maxima {
            while k + 1 < minima.count && minima[k + 1] < i { k += 1 }
            rises.append(minima[k] < i ? z[i] - z[minima[k]] : 0)
        }
        let sorted = rises.sorted()
        let q3 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.75))]
        let thr = 0.2 * q3
        let good = zip(maxima, rises).filter { $0.1 > thr }.map { $0.0 }
        guard good.count >= 2 else { return nil }
        let spacing = Double(good.last! - good.first!) / Double(good.count - 1) / fs
        return spacing > 0 ? 60 / spacing : nil
    }

    // MARK: - Pipeline
    /// `ppg`: mean of the green channels at `fs` (25 Hz), most recent sample last. `hintBPM`: the sensor's heart rate,
    /// used for the beat-detection refractory period. Analyses the last `window` seconds.
    static func estimate(ppg: [Double], fs: Double = 25, window: Double = 32, hintBPM: Double? = nil) -> Estimate? {
        let n = Int(window * fs)
        guard ppg.count >= n + Int(fs * 4) else { return nil }
        let x = Array(ppg.suffix(n + Int(fs * 4)))          // a few extra seconds so the filter settles before the window
        let pulse = bandpass(x, low: 0.5, high: 5, fs: fs)
        // Refractory period from the data itself (first pass ≤ 120 bpm, then 0.6 × median spacing). The sensor's own
        // heart rate is deliberately not used here: the EVK firmware's algorithm can sit at half the true rate.
        var pk = peaks(pulse, refractory: Int(0.5 * fs))
        guard pk.count >= 6 else { return nil }
        let d = zip(pk.dropFirst(), pk).map { Double($0 - $1) }.sorted()
        pk = peaks(pulse, refractory: Int(0.6 * d[d.count / 2]))
        guard pk.count >= 8 else { return nil }
        if let h = hintBPM, h > 30 {
            let detected = 60 * fs / d[d.count / 2]
            _ = h; _ = detected   // available for diagnostics; not used to steer detection
        }
        // features per beat
        var tb: [Double] = [], riav: [Double] = [], riiv: [Double] = []
        for i in 1..<pk.count {
            let a = pk[i - 1], b = pk[i]
            var tr = a, mn = pulse[a]
            for j in a..<b where pulse[j] < mn { mn = pulse[j]; tr = j }
            tb.append(refine(pulse, b) / fs)
            riav.append(pulse[b] - mn)
            riiv.append(x[max(0, tr - 2)...min(x.count - 1, tr + 2)].reduce(0, +) / 5)
        }
        let rifv = zip(tb.dropFirst(), tb).map { $0 - $1 }
        let tfv = Array(tb.dropFirst())
        // keep only the analysis window (drop the settling margin)
        let t0 = Double(x.count - n) / fs, t1 = Double(x.count) / fs
        let inWin = tfv.indices.filter { tfv[$0] >= t0 && tfv[$0] < t1 }
        guard inWin.count >= Int(window / 2.2) else { return nil }
        let ib = inWin.map { rifv[$0] }
        let mean = ib.reduce(0, +) / Double(ib.count)
        let cv = (ib.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(ib.count)).squareRoot() / mean
        guard cv <= 0.2, mean > 0.35, mean < 2.0 else { return nil }     // irregular beats: motion / misdetection
        let fs4 = 4.0
        func rate(_ t: [Double], _ v: [Double]) -> Double? {
            let sel = t.indices.filter { t[$0] >= t0 - 2 && t[$0] < t1 }
            guard sel.count >= 6 else { return nil }
            let y = resample(sel.map { t[$0] }, sel.map { v[$0] }, from: t0, to: t1, fs: fs4)
            let yb = bandpass(y, low: 0.1, high: 0.6, fs: fs4)
            return countOrig(yb, fs: fs4)
        }
        let eF = rate(tfv, rifv), eA = rate(tb, riav), eI = rate(tb, riiv)
        // Smart Fusion: mean of the modalities that agree; RIFV and RIAV must both be present and agree,
        // RIIV (most exposed to vasomotor waves on the wrist) joins only if it agrees with them.
        guard let f = eF, let a = eA, abs(f - a) <= 4 else {
            return nil
        }
        var members = [f, a]
        if let i = eI, abs(i - (f + a) / 2) <= 4 { members.append(i) }
        let m = members.reduce(0, +) / Double(members.count)
        let sd = (members.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(members.count)).squareRoot()
        guard m >= 6, m <= 36 else { return nil }
        return Estimate(rpm: m, rifv: eF, riav: eA, riiv: eI, spread: sd, beats: inWin.count)
    }
}
