# Cinematic style

The look for vertical talking heads that should feel like a film: a dark, moody grade, black letterbox bars, serif subtitles, and quiet chapter cards in muted gold. It should read like the opening of a film, not like a social video.

The frame is 1080×1920. Ready-made parts are in `src/` (HyperFrames compositions). Each one has its text and timings at the top of its script. Change those, then render. The rendered examples are in `assets/Motion/`.

| Part | File | Use |
|---|---|---|
| Captions | `src/captions/index.html` | Film subtitles in the bottom bar, one line at a time |
| Title card | `src/title-card/index.html` | The hook or a chapter: "CHAPTER II" and one headline over dimmed footage |
| Lower third | `src/lower-third/index.html` | Your name and one line, as an opening credit in the bottom bar |
| Figure | `src/figure/index.html` | One number or comparison over dimmed footage |

## Frame

- Two black bars, 300 px each, top and bottom. The picture sits between them (1080×1320). The bars stay on for the whole video.
- Grade every talking shot with `grade.footage` from `tokens.json`: deeper blacks, less colour, a little warmth.
- A soft vignette darkens the frame edges only. The face stays clean.
- Under a chapter card or a figure, the picture dims and softens (`grade.dimmed`). It comes back when the card goes.
- Frame the face in the top half of the picture. The subtitles live in the bottom bar, so they never cover the face.

## Colour

- `bar` is pure black. Never grey.
- Subtitles in `subtitle` (warm cream). Headlines, names and numerals in `title`.
- One accent: `gold`. Use it for the italic words that matter, the chapter kicker, the thin rule, and the number that matters. Never for decoration. If everything is gold, nothing is.
- Labels and sources in `muted`.

## Type

- Cormorant Garamond for everything. One family keeps the film look calm.
- Headlines: 400, 128 px on a 1080-wide frame. Put the second line in gold italic: "Discipline is *a calendar.*"
- Kickers and labels: 500, uppercase, wide tracking (12 px on a 30 px kicker). "CHAPTER II", "FIG. I — HOURS IN A WEEK".
- Roman numerals for chapters and figures.
- Phone test: at 360 px wide the subtitle must still read. Nothing under 28 px.

## Captions

- Subtitles, not karaoke. Cormorant Garamond 400, 56 px, centred in the bottom bar, sentence case.
- One line at a time, 36 characters or fewer. Never two lines.
- Mark the words that matter with `*stars*` in `LINES`. They turn gold italic. One emphasis per line at most.
- Each line fades in (0.5 s), holds still, and fades out (0.35 s).
- No box, no shadow, no highlight colour. The bar is the background.
- No captions during a chapter card, a figure or the lower third.

## Motion

The numbers are in `tokens.json` under `motion`.

- **Slow fades.** Lines fade up over 0.9 s (`power2.out`). They leave in about half the time.
- **One thing at a time:** the picture dims, then the kicker, then the first line, then the second line, then the rule draws from its centre.
- **Long holds.** A chapter card holds at least 2 s, plus 0.3 s for each word after three. Text never moves while it is read.
- **Cuts between shots are hard cuts.** Only the card and the dim fade.
- **Never:** zooms or push-ins on the person, tilts, shakes, film grain or light leaks on the person, wipes, flashes, words that bounce or slide, colour on the bars, text within 60 px of the frame edge, text over the face, a black first frame.

## Credits

- The lower third and title card start from HyperFrames blocks `lt-side-rule` and `titlecard-calm` (Apache-2.0, HeyGen), changed for this style. License: `src/LICENSES/hyperframes-Apache-2.0.txt`.
- The motion numbers start from the `motion-design` rules in claude-motion (MIT, whaleyxbt), made slower for this style. License: `src/LICENSES/claude-motion-MIT.txt`.
- Font: Cormorant Garamond (variable roman and italic), SIL Open Font License (`fonts/OFL-CormorantGaramond.txt`).
