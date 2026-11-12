# Sound FX previews

Six sounds the Plugins › Sound FX page plays before earshot is installed. Each one is
rendered from earshot's bank (github.com/Leonxlnx/earshot, MIT, commit 925ebe5), from code
only: no recordings, no `fit/` sounds. AAC at 128 kbps.

    EARSHOT_OFFLINE=1 python -I -m earshot sfx render <id> -o x.wav --sr 44100
    afconvert -f m4af -d aac -b 128000 x.wav <category>-<member>.m4a

Ids: swish/stick, impact/punch, riser/tension, click/snap, logo_sting/spark, sub_drop/808.

## Takes' own sounds: takes-bank.json

Sounds designed for Takes on earshot's recipes, loaded on top of earshot's bank: SoundFX.swift and
takes_mcp.py set `EARSHOT_BANK` to this file (the app copies it to Resources/SFX). They list, render
and take dur / apex / pitch like any bank sound, and gettakes.app/sounds renders its pages from them.
Each entry is a render block (complete params + seed); its seed is the first that passes earshot's audit.

    EARSHOT_OFFLINE=1 <earshot venv>/bin/python -I assets/sfx/takes-bank.py

2026-10-29: seven risers: riser/cymbal, trailer, snare_roll, edm_build, quick, reverse, sci_fi.
2026-10-29 (round 2, the most searched sounds earshot had no take on): notify/notification, riser/censor_beep,
riser/buzzer (the riser recipe held still: one steady tone) and pro_pop_in/heartbeat.
2026-10-30 (round 3): riser/beep_beep, riser/static and impact/thud. Alarm, doorbell, whistle, correct answer, laser and
water drop sounded wrong on earshot's recipes; gettakes.app/sounds makes those in its own sounds-src/synth.py.

## Real recordings: recordings.json and rec/

2026-11-08: The user picked real recordings over the bank's clicks and typing. Nine CC0 (public domain) sounds from
Freesound, each with its source in recordings.json: four mouse clicks (rec/click/mouse is the default click) and five
typing runs of 4 s (cut shorter, never looped). FLAC, mono, 48 kHz, peak at -1 dBFS. The Sound FX library lists them
first in Clicks and Typing and plays the file itself; make_sfx copies one into generated/, cut to dur. The default for
a keystroke stays earshot's typing_key/clicky, one take per key. gettakes.app/sounds renders its Click and Typing
versions from these same files.
