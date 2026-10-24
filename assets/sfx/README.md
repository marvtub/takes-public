# Sound FX previews

Six sounds the Plugins › Sound FX page plays before earshot is installed. Each one is
rendered from earshot's bank (github.com/Leonxlnx/earshot, MIT, commit 925ebe5), from code
only: no recordings, no `fit/` sounds. AAC at 128 kbps.

    EARSHOT_OFFLINE=1 python -I -m earshot sfx render <id> -o x.wav --sr 44100
    afconvert -f m4af -d aac -b 128000 x.wav <category>-<member>.m4a

Ids: swish/stick, impact/punch, riser/tension, click/snap, logo_sting/spark, sub_drop/808.
