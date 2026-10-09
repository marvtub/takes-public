"""Clean a recorded voice for a video (Takes runs it for the Voice button and the clean_voice tool). Diagnoses the recording first, then picks the steps.

  uv run --python 3.11 --with clearvoice --with soundfile --with numpy \
    clean_voice.py IN OUT.wav [options]

  --diagnose        only measure the recording and print the plan; write nothing
  --ab              also write OUT.ab.wav: one 12 s speech window through every candidate
                    chain, back to back, with the order in OUT.ab.txt. Use it on a new mic or room.
  --steps LIST      override the plan, e.g. "declip,dehum,clearvoice,sr" or "none"
  --lufs -14        target loudness
  --window S,E      seconds of IN to use for --ab (default: the densest 12 s of speech)

IN is the RAW recording (.mov/.mp4/.wav/.m4a). OUT is 48 kHz mono float WAV with the same timing
as IN, so cut it afterwards with the take's edit list. The voice chain (EQ + 3.5:1 compressor +
gain + -1 dBFS limiter) always runs exactly once, at the end, in float. A report is written to
OUT.report.json."""
import argparse, json, os, subprocess, tempfile, numpy as np, soundfile as sf

SR = 48000
CH = ("highpass=f=80,equalizer=f=160:t=q:w=0.8:g=2,equalizer=f=350:t=q:w=1.2:g=-1.5,"
      "equalizer=f=3500:t=q:w=1:g=2,"
      "acompressor=threshold={th}dB:ratio=3.5:attack=12:release=150:knee=6:detection=rms")
LIM = "alimiter=limit=0.89:attack=4:release=60:level=disabled"

# Decision thresholds. Calibrated on one take (sign-in-with-chatgpt take 2, clip-on mic, glass
# room -> ClearVoice, which sounded best). Adjust them with each new recording.
ECHO_MAX = -24     # echo tail (dB rel. the word) above this -> ClearVoice
SNR_MIN = 50       # speech-to-noise-floor (dB) below this -> ClearVoice
BW_MIN = 15000     # highest frequency with real speech energy (Hz) below this -> super-resolution
PHONE_BW = 7000    # below this it is phone-band: super-resolution cannot rebuild 4-8 kHz
HUM_DB = 12        # a 50/60 Hz line this far over its neighbours -> notch it
D = {}


def ff(args):
    subprocess.run(["ffmpeg", "-v", "error", "-y", *args], check=True)


def lufs(f, af="anull"):
    e = subprocess.run(["ffmpeg", "-hide_banner", "-i", f, "-af", af + ",ebur128=framelog=quiet",
                        "-f", "null", "-"], capture_output=True, text=True).stderr
    return float(e.rsplit("I:", 1)[1].split("LUFS")[0])


def clipped_runs(a):
    """hard clipping = 3+ IDENTICAL samples in a row at the file's peak (a limiter never makes these)"""
    m = np.abs(a).max(); hot = (np.abs(a) >= m * 0.999) & np.r_[False, np.diff(a) == 0]
    runs = np.diff(np.flatnonzero(np.diff(np.r_[0, hot.astype(int), 0])))[::2]
    return int((runs >= 2).sum())


def env_db(a, hop=480):
    k = len(a) // hop
    return 20 * np.log10(np.sqrt((a[:k * hop].reshape(k, hop) ** 2).mean(1)) + 1e-9)


def diagnose(a):
    e = env_db(a)                                  # 10 ms frames
    floor, loud = np.percentile(e, 10), np.percentile(e, 95)
    th = floor + 0.5 * (loud - floor)             # speech / not speech
    offs = [k for k in range(10, len(e) - 30) if e[k - 1] > th and e[k] <= th and (e[k:k + 20] < th).all()]
    echo = float(np.mean([np.mean(e[k + 3:k + 15]) - np.max(e[k - 10:k]) for k in offs])) if offs else None
    n = 4096; sp = np.zeros(n // 2 + 1); cnt = 0   # spectrum of speech frames only
    for k in np.flatnonzero(e > th)[::5]:
        s = a[k * 480:k * 480 + n]
        if len(s) == n: sp += np.abs(np.fft.rfft(s * np.hanning(n))) ** 2; cnt += 1
    sp = 10 * np.log10(sp / max(cnt, 1) + 1e-20); f = np.fft.rfftfreq(n, 1 / SR)
    ref = np.percentile(sp[(f > 200) & (f < 4000)], 90)
    bw = float(f[np.flatnonzero(sp > ref - 50)[-1]]) if (sp > ref - 50).any() else 0.0
    m = 16384; fq = np.fft.rfftfreq(m, 1 / SR)   # hum: 3 Hz bins, from the pauses, where the voice cannot mask it
    q = np.zeros(m // 2 + 1); qc = 0
    for k in np.flatnonzero(e < floor + 3)[::3]:
        s = a[k * 480:k * 480 + m]
        if len(s) == m: q += np.abs(np.fft.rfft(s * np.hanning(m))) ** 2; qc += 1
    q = 10 * np.log10(q / max(qc, 1) + 1e-20)
    def line(hz):
        i = int(np.argmin(abs(fq - hz))); nb = np.r_[q[i - 9:i - 4], q[i + 5:i + 10]]
        return float(q[i - 1:i + 2].max() - np.median(nb))
    hum = max((50, 60), key=line)
    return dict(peak_dbfs=round(float(20 * np.log10(np.abs(a).max() + 1e-12)), 1),
                clipped_runs=clipped_runs(a), noise_floor_db=round(float(floor), 1),
                snr_db=round(float(loud - floor), 1), echo_tail_db=None if echo is None else round(echo, 1),
                bandwidth_hz=round(bw), hum_hz=hum, hum_db=round(line(hum), 1), words_measured=len(offs))


def plan(d):
    steps, why = [], []
    if d["clipped_runs"] > 20:
        steps.append("declip"); why.append(f"{d['clipped_runs']} clipped runs in the recording (lower the mic gain next time)")
    if d["hum_db"] > HUM_DB:
        steps.append("dehum"); why.append(f"{d['hum_hz']} Hz hum, {d['hum_db']} dB over its neighbours")
    if (d["echo_tail_db"] is not None and d["echo_tail_db"] > ECHO_MAX) or d["snr_db"] < SNR_MIN:
        steps.append("clearvoice"); why.append(f"echo {d['echo_tail_db']} dB (limit {ECHO_MAX}), SNR {d['snr_db']} dB (limit {SNR_MIN})")
    if d["bandwidth_hz"] < BW_MIN:
        steps.append("sr"); why.append(f"bandwidth {d['bandwidth_hz']} Hz: low-rate audio, rebuild the highs")
        if d["bandwidth_hz"] < PHONE_BW:
            why.append("PHONE-BAND audio: super-resolution will not fill 4-8 kHz; A/B against Resemble Enhance (SKILL.md)")
    if not steps: why.append("clean recording: chain only")
    return steps, why


_cv = {}
def clearvoice(task, model, i, o):
    cache = os.path.expanduser("~/.cache/clearvoice"); os.makedirs(cache, exist_ok=True)
    cwd = os.getcwd(); os.chdir(cache)            # ClearVoice downloads checkpoints/ into the cwd
    try:
        from clearvoice import ClearVoice
        if model not in _cv: _cv[model] = ClearVoice(task=task, model_names=[model])
        _cv[model].write(_cv[model](input_path=i, online_write=False), output_path=o)
    finally:
        os.chdir(cwd)
    x, sr = sf.read(o)
    if sr != SR or x.ndim > 1:
        ff(["-i", o, "-ac", "1", "-ar", str(SR), "-c:a", "pcm_f32le", o + ".48k.wav"]); os.replace(o + ".48k.wav", o)


def super_res(cur, out, tmp, tag, chunk=12.0, ov=1.0):
    """ClearVoice MossFormer2_SR_48K. Two quirks: it only rebuilds above the input's Nyquist, so
    resample to the real bandwidth first; and it silently does nothing on inputs longer than
    ~20 s, so run it on 12 s chunks with 1 s linear crossfades."""
    rate = max([16000] + [r for r in (22050, 24000, 32000, 44100) if r / 2 <= D["bandwidth_hz"] * 1.1])
    x, _ = sf.read(cur); n = len(x); step = int((chunk - ov) * SR); L = int(chunk * SR); o = int(ov * SR)
    y = np.zeros(n); w = np.zeros(n)
    for i, s0 in enumerate(range(0, max(n - o, 1), step)):
        seg = x[s0:s0 + L]; p = f"{tmp}/{tag}-sr{i}.wav"; sf.write(p, seg, SR, subtype="FLOAT")
        ff(["-i", p, "-ar", str(rate), "-c:a", "pcm_f32le", p + ".low.wav"])
        clearvoice("speech_super_resolution", "MossFormer2_SR_48K", p + ".low.wav", p + ".sr.wav")
        z, _ = sf.read(p + ".sr.wav"); z = np.pad(z[:len(seg)], (0, max(0, len(seg) - len(z))))
        g = np.ones(len(seg)); k = min(o, len(seg))
        if s0 > 0: g[:k] = np.linspace(0, 1, k)
        if s0 + L < n: g[-k:] = np.minimum(g[-k:], np.linspace(1, 0, k))
        y[s0:s0 + len(seg)] += z * g; w[s0:s0 + len(seg)] += g
    sf.write(out, y / np.maximum(w, 1e-6), SR, subtype="FLOAT")


def run(src, steps, out, target, tmp, tag):
    cur = src
    for s in steps:
        nxt = f"{tmp}/{tag}-{s}.wav"
        if s == "declip": ff(["-i", cur, "-af", "adeclip", "-c:a", "pcm_f32le", nxt])
        elif s == "dehum":
            h = D["hum_hz"]
            ff(["-i", cur, "-af", ",".join(f"bandreject=f={h*k}:width_type=q:w=30" for k in (1, 2, 3, 4)), "-c:a", "pcm_f32le", nxt])
        elif s == "clearvoice": clearvoice("speech_enhancement", "MossFormer2_SE_48K", cur, nxt)
        elif s == "sr": super_res(cur, nxt, tmp, tag)
        else: raise SystemExit(f"unknown step {s}")
        cur = nxt
    ch = CH.format(th=lufs(cur, "highpass=f=80") + 2)
    ff(["-i", cur, "-af", f"{ch},volume={target - lufs(cur, ch):.2f}dB,{LIM}", "-ar", str(SR), "-ac", "1", "-c:a", "pcm_f32le", out])


def sync_ms(r, o):
    """cross-correlate 5 ms loudness envelopes (sample-level correlation is fooled by EQ phase)"""
    def env(x): h = 240; k = len(x) // h; return np.sqrt((x[:k * h].reshape(k, h) ** 2).mean(1))
    er, eo = env(r), env(o); k = min(len(er), len(eo)); er, eo = er[:k] - er[:k].mean(), eo[:k] - eo[:k].mean()
    c = [np.dot(er[max(0, d):k + min(0, d)], eo[max(0, -d):k - max(0, d)]) for d in range(-20, 21)]
    return (int(np.argmax(c)) - 20) * 5


def main():
    global D
    p = argparse.ArgumentParser()
    p.add_argument("inp"); p.add_argument("out", nargs="?")
    p.add_argument("--lufs", type=float, default=-14)
    p.add_argument("--diagnose", action="store_true"); p.add_argument("--ab", action="store_true")
    p.add_argument("--steps"); p.add_argument("--window")
    a = p.parse_args()
    tmp = tempfile.mkdtemp(prefix="voice-"); raw = f"{tmp}/raw.wav"
    ff(["-i", os.path.abspath(a.inp), "-vn", "-ac", "1", "-ar", str(SR), "-c:a", "pcm_f32le", raw])
    r, _ = sf.read(raw)
    D = diagnose(r); steps, why = plan(D)
    if a.steps is not None: steps, why = ([] if a.steps == "none" else a.steps.split(",")), ["--steps override"]
    print("diagnosis:", json.dumps(D))
    print("plan:", " -> ".join(steps + ["chain"]), "|", "; ".join(why))
    if D["clipped_runs"] > 20: print("WARNING: the recording is clipped. If this is not the raw take, find the raw take.")
    if a.diagnose or not a.out: return
    out = os.path.abspath(a.out); stem = out[:-4] if out.endswith(".wav") else out
    run(raw, steps, out, a.lufs, tmp, "main")
    o, _ = sf.read(out)
    rep = dict(input=os.path.abspath(a.inp), diagnosis=D, steps=steps, why=why,
               out=dict(peak_dbfs=round(float(20 * np.log10(np.abs(o).max() + 1e-12)), 1), clipped_runs=clipped_runs(o),
                        lufs=round(lufs(out), 1), sync_ms=sync_ms(r, o), seconds=round(len(o) / SR, 2), in_seconds=round(len(r) / SR, 2)),
               echo_after_db=diagnose(o)["echo_tail_db"])
    print("out:", json.dumps(rep["out"]), "| echo after:", rep["echo_after_db"])
    if a.ab:
        if a.window: s0, s1 = map(float, a.window.split(","))
        else:
            e = env_db(r); lo, hi = np.percentile(e, 10), np.percentile(e, 95)
            c = np.convolve((e > lo + 0.5 * (hi - lo)).astype(float), np.ones(1200), "valid")
            s0 = float(np.argmax(c)) / 100 if len(c) else 0.0; s1 = s0 + 12
        seg = f"{tmp}/seg.wav"; ff(["-ss", str(s0), "-to", str(s1), "-i", raw, "-c:a", "pcm_f32le", seg])
        pre = [x for x in steps if x in ("declip", "dehum")]
        cands = [("chain only", pre), ("clearvoice", pre + ["clearvoice"]),
                 ("clearvoice + super-resolution", pre + ["clearvoice", "sr"]), ("plan", steps)]
        seen, parts, order = set(), [], []
        for name, st in cands:
            if tuple(st) in seen: continue
            seen.add(tuple(st)); f = f"{tmp}/ab-{len(order)}.wav"; run(seg, st, f, a.lufs, tmp, f"ab{len(order)}")
            x, _ = sf.read(f); parts += [x, np.zeros(int(.8 * SR))]
            order.append(f"{chr(65 + len(order))}: {name} ({'+'.join(st) or 'no cleanup'} -> chain)")
        sf.write(stem + ".ab.wav", np.concatenate(parts), SR, subtype="FLOAT")
        open(stem + ".ab.txt", "w").write(f"window {s0:.1f}-{s1:.1f} s of the input, 0.8 s gap between versions\n" + "\n".join(order) + "\n")
        rep["ab"] = order; print("A/B:", stem + ".ab.wav"); print("\n".join(order))
    json.dump(rep, open(stem + ".report.json", "w"), indent=1)


if __name__ == "__main__":
    main()
