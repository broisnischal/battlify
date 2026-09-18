import AVFoundation
import Foundation

/// The sounds Battlify makes when power changes, synthesised rather than shipped.
///
/// Nothing here is a file. Three reasons, and they're the same reasons a system sound is
/// synthesised too:
///
///   - A recorded click is a recording of *one* click. Generated, the transient and the
///     tone are separately tunable, so the connect and disconnect cues can be built from
///     the same parts with different weight instead of being two unrelated samples.
///   - No decode, no disk, no bundle size. The buffers are a few kilobytes of Float and
///     they're built once, on first play.
///   - The cues share a tonal centre (G4) by construction, so plugging in, unplugging and
///     finishing charging sound like one instrument rather than three stock effects.
///
/// Everything is deliberately quiet and short. This fires while you're working: it has to
/// be over before it becomes something you notice twice. The visual side always says the
/// same thing (menu-bar glyph, overlay, notification) — the sound is never the only
/// channel, and it is off until you ask for it.
@MainActor
enum ChargeSound {

    /// What happened. Weight and length are matched to the event: connecting is the one
    /// worth a proper cue, disconnecting is an aside, finishing is the only one allowed a
    /// resolved chord.
    enum Cue: String, CaseIterable {
        /// Adapter connected — a seat-and-lift: transient, then a rising fifth.
        case connect
        /// Adapter pulled — the same transient, softer and smaller, and the tone falls.
        case disconnect
        /// Full, or held at your limit — an ascending triad. The end of the story, so
        /// it's the one thing here that's allowed to sound finished.
        case complete
    }

    /// Which instrument the cues are played on.
    ///
    /// One synthesiser, five voicings. They share the cue *structure* — a transient, a tone
    /// that moves, a triad for the end — and differ in timbre, length and how much of the
    /// room comes back, which is the difference between five sounds and five sound effects.
    /// Picking one is a taste decision nobody should have to justify, so they're all here.
    enum Theme: String, CaseIterable, Identifiable, Codable {
        /// The default: a connector seating, then taking hold. Warm, short, woody.
        case warm
        /// Struck glass. Inharmonic partials and a long tail, the way a real bell is a
        /// slightly wrong chord rather than one pitch.
        case glass
        /// Plucked. All attack and no tail, like a thumb piano.
        case pluck
        /// A square-wave blip. The sound of a device telling you something, on purpose.
        case blip
        /// Just the transient. No pitch at all, for anyone who wants to be told without
        /// being sung to.
        case tick

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .warm:  return "Warm"
            case .glass: return "Glass"
            case .pluck: return "Pluck"
            case .blip:  return "Blip"
            case .tick:  return "Tick"
            }
        }
    }

    /// Subtle by default. Feedback sound at unity is somebody else's decision about how
    /// loud your room is.
    static let defaultVolume = 0.3
    static let defaultTheme = Theme.warm

    /// Play `cue` at `volume` (0…1). Silently does nothing if the audio engine won't
    /// start — a battery app has no business raising an error because a chime failed.
    static func play(_ cue: Cue, volume: Double, theme: Theme = defaultTheme) {
        let level = min(1, max(0, volume))
        guard level > 0.001 else { return }
        guard let node = startedPlayer() else { return }

        node.volume = Float(level)
        // Re-triggering restarts the cue rather than queueing behind the last one:
        // plug-unplug-plug in quick succession should sound like the last thing that
        // happened, not like a backlog. `stop()` clears anything already scheduled.
        node.stop()
        node.scheduleBuffer(buffer(for: cue, theme: theme), at: nil, options: [],
                            completionHandler: nil)
        node.play()
        scheduleIdleTeardown()
    }

    // MARK: - Engine

    /// Nonisolated: `Mix` below is a plain value type doing arithmetic, and there's no
    /// reason for it to hop to the main actor to read a constant.
    nonisolated private static let rate = 44_100.0
    private static let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    private static var engine: AVAudioEngine?
    private static var player: AVAudioPlayerNode?
    private static var idleTeardown: Task<Void, Never>?
    private static var cache: [String: AVAudioPCMBuffer] = [:]

    /// One engine, built on demand and reused. Standing up an `AVAudioEngine` per sound
    /// is both slow and audible — the graph takes tens of milliseconds to come up, which
    /// lands the cue after the moment it's describing.
    private static func startedPlayer() -> AVAudioPlayerNode? {
        idleTeardown?.cancel()
        if let player, engine?.isRunning == true { return player }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            return nil
        }
        Self.engine = engine
        Self.player = player
        return player
    }

    /// Tear the graph down once the cues stop coming. An idle `AVAudioEngine` holds the
    /// output device awake, and on a laptop that is measurable — which is a poor look for
    /// this app in particular. The synthesised buffers survive; rebuilding the graph is
    /// cheap, re-synthesising is not.
    private static func scheduleIdleTeardown() {
        idleTeardown?.cancel()
        idleTeardown = Task { [engine, player] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            player?.stop()
            engine?.stop()
            if Self.engine === engine { Self.engine = nil; Self.player = nil }
        }
    }

    private static func buffer(for cue: Cue, theme: Theme) -> AVAudioPCMBuffer {
        let key = "\(theme.rawValue).\(cue.rawValue)"
        if let cached = cache[key] { return cached }
        let built = pcm(from: samples(for: cue, theme: theme))
        cache[key] = built
        return built
    }

    private static func pcm(from samples: [Float]) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        return buffer
    }

    // MARK: - Synthesis

    private static func samples(for cue: Cue, theme: Theme) -> [Float] {
        switch theme {
        case .warm:  return warm(cue)
        case .glass: return glass(cue)
        case .pluck: return pluck(cue)
        case .blip:  return blip(cue)
        case .tick:  return tick(cue)
        }
    }

    /// Struck glass: inharmonic partials, long tail, a lot of room.
    ///
    /// The ratios are a bell's, not an octave's. A real bell's overtones sit at roughly
    /// 2.76 and 5.40 times the fundamental, which is why a bell reads as one voice with a
    /// shimmer rather than as a chord — spacing them by octaves instead gives an organ.
    private static func glass(_ cue: Cue) -> [Float] {
        let bell: [(Double, Double, Double)] = [(2.76, 0.30, 2.0), (5.40, 0.12, 3.5)]
        switch cue {
        case .connect:
            var mix = Mix(length: seconds(1.05))
            mix.add(click(burst: 0.003, frequency: 5200, q: 2.2, gain: 0.10), at: 0)
            mix.add(tone(from: 523, to: 784, sweep: 0.05, decay: 0.95, gain: 0.44,
                         partials: bell), at: 0.003)
            return mix.space(delay: 0.041, feedback: 0.40, mix: 0.34).finish(peak: 0.86)
        case .disconnect:
            var mix = Mix(length: seconds(0.62))
            mix.add(tone(from: 784, to: 523, sweep: 0.07, decay: 0.52, gain: 0.34,
                         partials: bell), at: 0)
            return mix.space(delay: 0.037, feedback: 0.34, mix: 0.26).finish(peak: 0.56)
        case .complete:
            var mix = Mix(length: seconds(1.45))
            for (index, note) in [523.0, 659.0, 784.0].enumerated() {
                mix.add(tone(from: note, to: note * 1.004, sweep: 0.04,
                             decay: 0.60 + 0.25 * Double(index), gain: 0.30, partials: bell),
                        at: 0.13 * Double(index))
            }
            return mix.space(delay: 0.043, feedback: 0.42, mix: 0.36).finish(peak: 0.82)
        }
    }

    /// Plucked: all attack, almost no tail. The fourth partial carries the wood.
    private static func pluck(_ cue: Cue) -> [Float] {
        let wood: [(Double, Double, Double)] = [(2.0, 0.26, 3.0), (4.0, 0.16, 5.0)]
        switch cue {
        case .connect:
            var mix = Mix(length: seconds(0.30))
            mix.add(click(burst: 0.004, frequency: 1600, q: 1.2, gain: 0.22), at: 0)
            mix.add(tone(from: 440, to: 466, sweep: 0.03, decay: 0.22, gain: 0.60,
                         partials: wood), at: 0.002)
            return mix.space(delay: 0.017, feedback: 0.22, mix: 0.14).finish(peak: 0.88)
        case .disconnect:
            var mix = Mix(length: seconds(0.22))
            mix.add(click(burst: 0.004, frequency: 1300, q: 1.2, gain: 0.16), at: 0)
            mix.add(tone(from: 392, to: 330, sweep: 0.03, decay: 0.15, gain: 0.42,
                         partials: wood), at: 0.002)
            return mix.space(delay: 0.015, feedback: 0.18, mix: 0.10).finish(peak: 0.56)
        case .complete:
            var mix = Mix(length: seconds(0.58))
            for (index, note) in [440.0, 554.0, 659.0].enumerated() {
                mix.add(tone(from: note, to: note * 1.003, sweep: 0.02, decay: 0.20,
                             gain: 0.38, partials: wood), at: 0.075 * Double(index))
            }
            return mix.space(delay: 0.019, feedback: 0.24, mix: 0.16).finish(peak: 0.84)
        }
    }

    /// A square-wave blip, dry. This one is *meant* to sound like a machine, so it gets no
    /// room at all: reverb on a square wave is a chiptune pretending to be in a hall.
    private static func blip(_ cue: Cue) -> [Float] {
        switch cue {
        case .connect:
            var mix = Mix(length: seconds(0.20))
            mix.add(tone(from: 660, to: 990, sweep: 0.05, decay: 0.15, gain: 0.50,
                         partials: [], wave: .square), at: 0)
            return mix.finish(peak: 0.72)
        case .disconnect:
            var mix = Mix(length: seconds(0.16))
            mix.add(tone(from: 660, to: 440, sweep: 0.04, decay: 0.12, gain: 0.40,
                         partials: [], wave: .square), at: 0)
            return mix.finish(peak: 0.52)
        case .complete:
            var mix = Mix(length: seconds(0.42))
            for (index, note) in [660.0, 880.0, 1320.0].enumerated() {
                mix.add(tone(from: note, to: note, sweep: 0.01, decay: 0.09, gain: 0.40,
                             partials: [], wave: .square), at: 0.10 * Double(index))
            }
            return mix.finish(peak: 0.70)
        }
    }

    /// Transients only. Two for connect, one for unplug, three for done — the same
    /// grammar the haptics use, which is the point: this is the version for people who
    /// want the information and none of the music.
    private static func tick(_ cue: Cue) -> [Float] {
        switch cue {
        case .connect:
            var mix = Mix(length: seconds(0.16))
            mix.add(click(burst: 0.005, frequency: 2000, q: 1.5, gain: 0.55), at: 0)
            mix.add(click(burst: 0.004, frequency: 2600, q: 1.5, gain: 0.40), at: 0.055)
            return mix.finish(peak: 0.70)
        case .disconnect:
            var mix = Mix(length: seconds(0.10))
            mix.add(click(burst: 0.005, frequency: 1500, q: 1.4, gain: 0.45), at: 0)
            return mix.finish(peak: 0.48)
        case .complete:
            var mix = Mix(length: seconds(0.26))
            for index in 0..<3 {
                mix.add(click(burst: 0.004, frequency: 2000 + 400 * Double(index),
                              q: 1.6, gain: 0.40), at: 0.055 * Double(index))
            }
            return mix.finish(peak: 0.66)
        }
    }

    private static func warm(_ cue: Cue) -> [Float] {
        switch cue {
        case .connect:
            // Transient first, tone a hair behind it: the sound of something seating and
            // then taking hold. The interval is a rising perfect fifth (G4→D5) because a
            // fifth resolves upward without sounding like an alert.
            var mix = Mix(length: seconds(0.40))
            // 2.4 kHz, not 4.2 kHz, and a third of the level it used to have.
            //
            // The transient was the loudest thing in the cue and sat in the 2–5 kHz band
            // where hearing is most sensitive and tires fastest. That is the exact
            // ingredient that makes a synthesised interface sound plasticky: it reads as a
            // tick laid on top of a tone rather than as the attack *of* the tone. Lower,
            // wider (Q 1.6 rather than 3.0) and quieter turns it into body.
            mix.add(click(burst: 0.006, frequency: 2400, q: 1.6, gain: 0.26), at: 0)
            mix.add(tone(from: 392, to: 588, sweep: 0.085, decay: 0.30, gain: 0.56), at: 0.004)
            return mix.space(delay: 0.023, feedback: 0.30, mix: 0.22)
                      .finish(peak: 0.90)

        case .disconnect:
            // Half the length and two thirds the level of connect, and the tone falls.
            // Losing power shouldn't feel like an event you have to look up from.
            var mix = Mix(length: seconds(0.26))
            mix.add(click(burst: 0.005, frequency: 1900, q: 1.4, gain: 0.18), at: 0)
            mix.add(tone(from: 523, to: 330, sweep: 0.060, decay: 0.17, gain: 0.38), at: 0.003)
            return mix.space(delay: 0.019, feedback: 0.24, mix: 0.16)
                      .finish(peak: 0.58)

        case .complete:
            // G major, ascending, 100ms apart — slow enough to hear as three notes rather
            // than a chord, short enough to be over in half a second. Same root as the
            // connect cue, so finishing sounds like the end of the same phrase.
            var mix = Mix(length: seconds(0.78))
            mix.add(click(burst: 0.004, frequency: 2800, q: 1.8, gain: 0.12), at: 0)
            for (index, note) in [392.0, 494.0, 587.0].enumerated() {
                // The last note rings longest. Three notes decaying identically read as
                // three separate events; letting the tail lengthen up the phrase makes them
                // one gesture that lands on the third.
                mix.add(tone(from: note, to: note * 1.005, sweep: 0.04,
                             decay: 0.30 + 0.10 * Double(index), gain: 0.34),
                        at: 0.10 * Double(index))
            }
            return mix.space(delay: 0.031, feedback: 0.34, mix: 0.26)
                      .finish(peak: 0.80)
        }
    }

    private static func seconds(_ t: Double) -> Int { Int(t * rate) }

    /// Amplitude at sample `i` of an envelope decaying to −60 dB over `duration`.
    ///
    /// Exponential, not linear. Physical things lose energy in proportion to how much
    /// they have, so a linear fade is the one decay shape nothing in the world makes —
    /// it reads as a sound being turned down rather than dying away. The floor is 0.001
    /// rather than 0 for the same reason a Web Audio `exponentialRampToValueAtTime` can't
    /// target zero: the curve never gets there, so the tail is cut cleanly instead (see
    /// `Mix.finish`).
    private static func decay(_ i: Int, over duration: Double) -> Double {
        exp(-6.907755 * Double(i) / (rate * duration))      // ln(1000) = 6.907755
    }

    /// A click: a few milliseconds of noise through a bandpass.
    ///
    /// Not an oscillator. A click is broadband by nature — it's the sound of two surfaces
    /// meeting, which has no pitch — and a short sine burst instead gives you a "bip",
    /// which is the sound of a device, not of a connector. The bandpass supplies the only
    /// pitch it should have: which surfaces, how hard.
    ///
    /// `burst` is the noise itself (5–15ms is the whole useful range; past that it stops
    /// being a click and becomes a hiss). The buffer runs on past it so the filter's own
    /// ring decays instead of being chopped mid-cycle, which would be a second click.
    private static func click(burst: Double, frequency: Double, q: Double,
                              gain: Double) -> [Float] {
        let noiseCount = Int(burst * rate)
        let tail = Int(0.030 * rate)
        var out = [Float](repeating: 0, count: noiseCount + tail)

        // Bandpass (RBJ cookbook, constant 0 dB peak). Q stays in 2…5: below that the
        // click is a thud with no location, above it the filter rings on a single pitch
        // and the click turns into a bell.
        let w0 = 2 * Double.pi * frequency / rate
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        let b0 = alpha / a0, b2 = -alpha / a0
        let a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        // Seeded so the cue is byte-identical every play and can be cached. A click that
        // differs each time is nicer in a game; here it would just defeat the cache.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func noise() -> Double {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Double(Int64(bitPattern: seed)) / Double(Int64.max)
        }

        for i in 0..<out.count {
            // The burst is itself shaped, so the noise doesn't start at full level: a
            // rectangular gate has a step edge, and a step edge is a click of its own.
            let x = i < noiseCount ? noise() * decay(i, over: burst) : 0
            let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            out[i] = Float(y * gain)
        }
        return out
    }

    /// A tone with the pitch moving. A static frequency is the tell of a synthesised UI
    /// sound — real resonators shift as they settle — so every tone here sweeps, even the
    /// triad notes, which drift by half a percent.
    ///
    /// The sweep is exponential because pitch is perceived logarithmically: a linear ramp
    /// from 392 to 588 spends most of its time in the top half of the interval.
    /// Which shape the fundamental is. Sine for everything that wants to sound struck or
    /// blown; square for the one theme that wants to sound like a circuit.
    private enum Wave { case sine, square }

    /// `partials` is (ratio, gain, decayDivisor): a voice's timbre in three numbers per
    /// overtone. The default is the warm theme's — an octave for edge and a twelfth for
    /// the struck quality — and a theme passes its own to be a different instrument rather
    /// than the same one transposed.
    private static func tone(from: Double, to: Double, sweep: Double,
                             decay decayTime: Double, gain: Double,
                             partials: [(Double, Double, Double)] = [(2.0, 0.22, 3.0),
                                                                     (3.0, 0.09, 5.0)],
                             wave: Wave = .sine) -> [Float] {
        let count = Int(decayTime * rate)
        var out = [Float](repeating: 0, count: count)
        let sweepSamples = max(1.0, sweep * rate)
        var phase = 0.0

        for i in 0..<count {
            let p = min(1.0, Double(i) / sweepSamples)
            let frequency = from * pow(to / from, p)
            phase += 2 * .pi * frequency / rate

            // The partials decay faster than the fundamental, each by its own divisor: they
            // give the attack its character and are gone before the body, which is what
            // stops a tone sounding like a test signal. One partial is a synthesiser; the
            // ear needs two or three to hear a struck object.
            func osc(_ multiple: Double) -> Double {
                let x = sin(phase * multiple)
                return wave == .sine ? x : (x >= 0 ? 1 : -1) * 0.5
            }
            var voice = osc(1) * decay(i, over: decayTime)
            for (ratio, level, divisor) in partials {
                voice += osc(ratio) * decay(i, over: decayTime / divisor) * level
            }

            // A 1.5ms fade-in. Starting a sine at full amplitude is a discontinuity, and
            // a discontinuity is a click — an unintended one, on top of the one we meant.
            let attack = min(1.0, Double(i) / (0.0015 * rate))
            out[i] = Float(voice * attack * gain)
        }
        return out
    }

    /// Somewhere to lay voices down at their own offsets and get a finished buffer back.
    private struct Mix {
        var samples: [Float]

        init(length: Int) { samples = [Float](repeating: 0, count: length) }

        mutating func add(_ voice: [Float], at offset: Double) {
            let start = Int(offset * ChargeSound.rate)
            for i in 0..<voice.count where start + i < samples.count {
                samples[start + i] += voice[i]
            }
        }

        /// Scale so the loudest sample sits at `peak`, then fade the last 3ms to true
        /// zero.
        ///
        /// Both halves matter. Normalising is how the cues are made comparable — the
        /// difference in weight between connect and disconnect should be a decision, not
        /// an accident of how many voices each happens to sum. And the fade is because an
        /// exponential envelope is still at −60 dB when the buffer ends: 0.001 is
        /// inaudible on its own but the *step* from it to silence is not, and it would
        /// land on every single play.
        /// A room, cheaply.
    ///
    /// Every cue here decayed into absolute silence, which is a thing that happens nowhere
    /// — even a click on a desk has a few milliseconds of the room coming back. Dry decay
    /// is most of why a synthesised cue sounds like it was generated rather than recorded.
    ///
    /// Two feedback taps a prime-ish interval apart, at low mix. Not a reverb: a suggestion
    /// that the sound happened somewhere. Feedback stays well under 0.5 so the tail dies
    /// inside the buffer instead of ringing on to whatever length it was given, and the
    /// second tap is offset so the two don't reinforce into an audible pitch.
    func space(delay: Double, feedback: Double, mix: Double) -> Mix {
        var copy = self
        let d1 = Int(delay * ChargeSound.rate)
        let d2 = Int(delay * 1.37 * ChargeSound.rate)
        guard d1 > 0, d2 > d1, d2 < copy.samples.count else { return copy }

        for i in d1..<copy.samples.count {
            copy.samples[i] += copy.samples[i - d1] * Float(feedback * mix)
        }
        for i in d2..<copy.samples.count {
            copy.samples[i] += copy.samples[i - d2] * Float(feedback * mix * 0.7)
        }
        return copy
    }

    /// Normalise to a fixed peak, then fade the last few milliseconds.
    ///
    /// Non-mutating so it can be chained after `space`, which returns a new `Mix` — a
    /// mutating method can't be called on the result of a function.
    func finish(peak: Double) -> [Float] {
            var out = samples
            let loudest = out.reduce(0.0) { max($0, Double(abs($1))) }
            guard loudest > 0 else { return out }
            let scale = Float(peak / loudest)
            for i in out.indices { out[i] *= scale }

            // Never end on a non-zero sample: that edge is a click, and it would undo
            // everything the softened transients just bought.
            let fade = min(out.count, Int(0.003 * ChargeSound.rate))
            for i in 0..<fade {
                out[out.count - fade + i] *= Float(1 - Double(i) / Double(fade))
            }
            return out
        }
    }
}
