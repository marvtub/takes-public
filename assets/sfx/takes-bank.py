"""Builds takes-bank.json: Takes' own sounds on earshot's recipes, loaded on top of earshot's bank through
EARSHOT_BANK (SoundFX.swift and takes_mcp.py set it). Each entry is a forge render block: complete params + seed.
The first seed whose render passes earshot's audit (earshot.forge.sfx.check) is kept.

    EARSHOT_OFFLINE=1 <earshot venv>/bin/python -I assets/sfx/takes-bank.py
"""
import json, os, numpy as np
from earshot.forge import bank, dsp
from earshot.forge.recipes import riser as R, notify, popin, impact
from earshot.forge.sfx import check

def full(p):  # complete params like the bank stores them
    return {**R.DEFAULTS, **R.R6_OFF, 'metal_db': -48.0, 'metal_f': 2600.0, 'blip_dec': 0.35, 'drone_oct': 0.08,
            'drone_noise': 0.0, 'metal_n': 9, 'metal_glide': 0.0, 'nb_q': 6.0, **p}

T, F, P = R.R6['tension'], R.FAMILIES, R.PRO
D = {
 # a reverse cymbal: metal wash and bright noise swelling into the hit, no tone
 'cymbal': (F['cymbal'] | {'metal_n': 28, 'metal_glide': 0.45},
            'a reverse cymbal: a bright metal wash swelling into the hit, no tone'),
 # a dark trailer build: a saw chord from 70 Hz, a rumble gliding up under it, a tremolo speeding up
 'trailer': (F['tension'] | {'length': 3.6, 'curve': 2.6, 'tf0': 70.0, 'toct': 2.5, 'tbright': 4.0, 'detune': 20.0,
             'drone_db': -10.0, 'drone_f': 40.0, 'drone_oct': 1.0, 'drone_noise': 0.6, 'noise_db': -8.0,
             'nf0': 200.0, 'nf1': 7000.0, 'sat': 6.0, 'hp': 90.0, 'gate_p0': 0.3, 'gate_p1': 0.045,
             'gate_depth': 0.5, 'verb': 0.35, 'rt60': 2.8},
             'a dark trailer build: a low saw chord and a rumble climbing for 3.6 s'),
 # a snare roll: noise hits speeding up from 6 to 40 a second
 'snare_roll': (P['roll'] | {'length': 2.6, 'curve': 2.0, 'gate_p0': 0.16, 'gate_p1': 0.025, 'gate_duty': 0.35,
                'rise_db': 30.0, 'nf0': 1500.0, 'nf1': 11000.0, 'hp': 220.0, 'drone_db': -48.0, 'verb': 0.18, 'rt60': 1.2},
                'a snare-roll build: noise hits speeding up from 6 to 40 a second'),
 # an EDM build: a detuned saw chord with its fifth, hard gate rolling 4 -> 45 Hz, a short duck before the drop
 'edm_build': (T | {'length': 3.6, 'curve': 2.6, 'fifth_db': -3.0, 'gate_depth': 0.95, 'gate_p0': 0.25,
               'gate_p1': 0.022, 'gate_sharp': 0.9, 'gate_pow': 1.8, 'pre_dip_ms': 40.0, 'detune': 26.0,
               'noise_db': -6.0, 'rswell_db': -16.0, 'rswell_rt': 2.0},
               'an EDM build: a wide saw chord chopped faster and faster, a short duck before the drop'),
 # a quick one: 0.9 s pitch rush for a fast cut
 'quick': (R.R6['rush'] | {'length': 0.9, 'curve': 2.0, 'toct': 2.6, 'gate_depth': 0.25, 'gate_sharp': 0.2,
           'rise_db': 22.0, 'end_ms': 3.0},
           'a quick 0.9 s rush for a fast cut: a bright band and a sine chord shooting up'),
 # a reverse reverb swell, long and soft, no tone
 'reverse': (R.R6['swell'] | {'length': 3.2, 'curve': 3.0, 'rise_db': 40.0, 'tone_db': -36.0, 'oct_db': -36.0,
             'rswell_db': 0.0, 'rswell_rt': 3.6, 'gate_depth': 0.0, 'noise_db': -12.0, 'width': 0.9, 'hp': 350.0},
             'a reverse reverb swell: a long soft breath into the hit, no tone'),
 # sci-fi: band-passed noise blips stepping up almost 3 octaves on an accelerating gate (from pro_riser/nblips:
 # tone blips read as a cheap synth whip to the audit at most lengths)
 'sci_fi': (bank.get('pro_riser/nblips')['params'] | {'length': 2.0, 'toct': 2.8, 'tf0': 1000.0, 'verb': 0.25,
            'rt60': 1.8, 'width': 0.6},
            'a sci-fi build: bright blips stepping up almost 3 octaves, faster and faster'),
}
# Round 2 (2026-10-29): the most searched sounds earshot had no take on. id: (recipe, params, about)
FLAT = {'curve': 1.0, 'rise_db': 0.0, 'noise_db': -60.0, 'tone_db': 0.0, 'tmode': 'glide', 'toct': 0.0, 'detune': 0.0,
        'oct_db': -60.0, 'shep_db': -60.0, 'drone_db': -60.0, 'gate_depth': 0.0, 'verb': 0.0, 'width': 0.0, 'hp': 60.0,
        'end_ms': 12.0, 'rswell_db': -60.0, 'metal_db': -60.0}   # the riser held still: one steady tone, nothing rising
D2 = {
 # a phone-style notification: the pro_notify success patch, two notes a fourth apart from E6
 'notify/notification': ('notify', {**notify.DEFAULTS, **bank.get('pro_notify/ding_1822')['params'],
                         **notify.FAMILY['pro_notify'][0], 'f0': 1318.5, 'interval': 5, 'gap': 0.075, 'length': 0.5},
                         'a phone-style notification: two bright notes a fourth apart'),
 # the TV censor beep: a pure 1 kHz sine, flat, hard in and out
 'riser/censor_beep': ('riser', full(FLAT | {'length': 0.8, 'wave': 'sine', 'tf0': 1000.0, 'tbright': 1.0, 'sat': 0.0}),
                       'the TV censor beep: a pure steady 1 kHz tone'),
 # a game-show wrong-answer buzzer: a driven 110 Hz saw with a fast rattle
 'riser/buzzer': ('riser', full(FLAT | {'length': 0.9, 'wave': 'saw', 'tf0': 110.0, 'tbright': 6.0, 'detune': 8.0, 'sat': 9.0,
                  'gate_depth': 0.35, 'gate_on': 0.0, 'gate_p0': 0.033, 'gate_p1': 0.033, 'gate_sharp': 0.0}),
                  'a wrong-answer buzzer: a harsh 110 Hz saw with a fast rattle'),
 # one heartbeat: lub-dub, two low thumps 0.16 s apart, no tick on top
 'pro_pop_in/heartbeat': ('popin', {**bank.get('pro_pop_in/deep')['params'], 'body_f': 52.0, 'drop': 0.3, 'dbl': 0.75,
                          'dbl_dt': 0.16, 'dbl_ratio': 0.92, 'length': 0.42, 'tick_db': -60.0, 'glass': 0.0, 'air_db': -60.0,
                          'contact_db': -60.0, 'ring_db': -60.0, 'knock': 0.0, 'sub': 0.6, 'harm': 0.25, 'sat': 3.0,
                          'lp': 700.0, 'att_ms': 10.0, 'hold_ms': 12.0, 'rel_ms': 22.0, 'release_ms': 40.0},
                          'one heartbeat: lub-dub, two low thumps'),
}
# Round 3 (2026-10-30): more of the most searched. Alarm, doorbell, whistle, correct answer, laser and water drop sounded
# wrong on these recipes; gettakes.app makes those in its own sounds-src/synth.py
GATE = {'gate_depth': 1.0, 'gate_on': 0.0, 'gate_sharp': 1.0}
D3 = {
 # beep beep: two short 1.2 kHz sine beeps
 'riser/beep_beep': ('riser', full(FLAT | GATE | {'length': 0.55, 'wave': 'sine', 'tf0': 1200.0, 'tbright': 1.0, 'sat': 0.0,
                     'gate_p0': 0.28, 'gate_p1': 0.28, 'gate_duty': 0.6}),
                     'beep beep: two short 1.2 kHz beeps'),
 # TV static: steady bright noise, no tone
 'riser/static': ('riser', full(FLAT | {'length': 2.0, 'tone_db': -60.0, 'noise_db': 0.0, 'nf0': 9000.0, 'nf1': 9000.0,
                  'pink': 0.15, 'nq': 0.7, 'sat': 0.0, 'width': 0.6}),
                  'TV static: steady bright noise'),
 # a thud: impact/deep with no crack or debris, a short low body
 'impact/thud': ('impact', {**impact.DEFAULTS, **bank.get('impact/deep')['params'], 'crack': 0.0, 'debris': 0.0,
                 'blast': 0.1, 'pre': 0.0, 'hall_wet': 0.15, 'hall_rt': 0.6, 'roll': 0.0, 'roll_hold': 0.3,
                 'body_f0': 110.0, 'body_f1': 50.0, 'sub_tau': 0.35, 'body_tau': 0.18},
                 'a soft low thud: a body hitting the floor, no crack'),
}
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'takes-bank.json')
SEEDS = [9101, 9102, 9103, 9104, 9105, 9106]
GRID = [round((4 / 3) ** k, 4) for k in range(-3, 4)]   # the lengths gettakes.app/sounds offers, x the default
TMP = OUT + '.tmp'


def passes(i, e):
    """how many GRID lengths pass the audit through bank.render (the default must)"""
    json.dump({'bank': 1, 'name': 'tmp', 'version': 'tmp', 'entries': {i: e}}, open(TMP, 'w'))
    os.environ['EARSHOT_BANK'] = TMP
    bank.reload()
    base = min(3.0, bank.render(i)[1].get('dur_s') or e['params'].get('length', 1.0))   # the site caps its default at 3 s
    ok = {g: bank.render(i, dur=base * g)[1]['checks']['ok'] for g in GRID if 0.04 <= base * g <= 3.0}
    return (sum(ok.values()) if ok[1.0] and bank.render(i)[1]['checks']['ok'] else 0), len(ok)


entries, report = {}, []
ALL = {f'riser/{n}': ('riser', full(p), about) for n, (p, about) in D.items()} | D2 | D3
for i, (rec, params, about) in ALL.items():
    cat, name = i.split('/')
    M = {'riser': R, 'notify': notify, 'popin': popin, 'impact': impact}[rec]
    best = None
    for seed in SEEDS:
        e = {'type': 'forge', 'category': cat, 'member': name, 'recipe': rec, 'fn': 'render',
             'params': params, 'seed': seed, 'peak_db': -1.0, 'gain_db': 0.0, 'mode': 'designed', 'notes': about}
        n, of = passes(i, e)
        if n and (best is None or n > best[0]):
            best = (n, of, seed)
        if n == of:
            break
    if best is None:
        raise SystemExit(f'{name}: no seed passes the audit')
    n, of, seed = best
    y = bank.normalize(np.asarray(M.render(params, dsp.rng(seed)), np.float64))
    m = bank.meta_of(y)
    entries[i] = {'type': 'forge', 'category': cat, 'member': name, 'recipe': rec, 'fn': 'render',
        'params': params, 'seed': seed, 'peak_db': -1.0, 'gain_db': 0.0, 'mode': 'designed', 'notes': about, 'meta': m}
    report.append((i, 'seed', seed, f'{n}/{of} lengths clean', m['dur_s'], 's, peak at', m['peak_s'], 'lufs_m_max', m['lufs_m_max']))
os.remove(TMP)
for r in report: print(*r)
json.dump({'bank': 1, 'name': 'takes', 'version': 'takes1', 'earshot': '0.3.0',
           'note': 'sounds designed for Takes (built by takes-bank.py) on earshot recipes (forge entries: params + seed); rendered by earshot >= 0.3.0 via EARSHOT_BANK',
           'categories': {}, 'entries': entries}, open(OUT, 'w'), indent=1)
