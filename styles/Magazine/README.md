# Magazine style

The look for talking-head explainers: full-screen footage, paper pages with thin-line figures, and text-only cards. It should read like a print magazine, not like a slide deck.

Ready-made parts are in `src/` (HyperFrames compositions). Each one has its text and timings at the top of its script. Change those, then render. The rendered examples are in `assets/Motion/`.

| Part | File | Use |
|---|---|---|
| Title card | `src/title-card/index.html` | The hook or a chapter: one headline on paper |
| Lower third | `src/lower-third/index.html` | Your name and one line, the first time you are on screen |
| Captions | `src/captions/index.html` | One phrase at a time, karaoke on the spoken word |
| Figure page | `src/figure/index.html` | One number or comparison, as a magazine figure |

## Colour

- Paper `paper` with 8% multiply grain. Text in `ink`. Sources and subtitles in `muted`.
- One accent: `accent` (oxblood). Use it only for the number that matters and for the FIG. kicker. Never for decoration. If everything is red, nothing is.
- Hairlines and chart lines in `rule`.

## Type

- Instrument Serif for headlines and numerals. Put the second half of a headline in italic: "A hundred times *bigger.*"
- Inter 500 in small caps (16 px, 0.2em tracking) for labels, running headers and credits.
- Captions: Inter 600, 42 px on a 1080-wide frame, sentence case, left-aligned, one phrase at a time (26 characters or fewer).
- Captions are sans and the copy is serif, so a caption never looks like copy.
- Phone test: at 360 px wide the headline must still read.

## Captions

- White with a soft shadow on footage. `ink` on paper.
- Karaoke: each word goes from 40% to 100% opacity as it is spoken. No box, no highlight colour.
- No captions on text cards (the card is the line) or during the title card.

## Page furniture

- A running header "TOPIC · page no." with a hairline rule.
- A red kicker "FIG. n — what it shows".
- An 88 px serif title.
- The source as a muted footnote.

## Charts

Thin lines, no gridlines, big serif numerals. Squares with true area (side ∝ √value) for scale. Hairline bars and timelines for comparisons.

## Motion

The numbers are in `tokens.json` under `motion`.

- **Entrances** ease out (`ease-out`). **Exits** ease in, and take about half as long as the entrance.
- **Words** arrive one by one, 0.09 s apart, rising 30 px out of a 12 px blur.
- **Footage to page:** the same video shrinks into the photo frame, or grows back (0.75 s, `ease-in-out`, transforms only).
- **Text cards:** hard cuts in and out.
- **Hold** every line you want read: at least 1 s for a short phrase, plus 0.25 s for each word after three. Text never moves while it is read.
- **Never:** wipes, flashes, ribbons, linear easing on anything that starts or stops, two things moving for attention at once, text within 60 px of the frame edge, a black first frame.

## Credits

- The lower third and title card start from HyperFrames blocks `lt-side-rule` and `titlecard-calm` (Apache-2.0, HeyGen), changed for this style. License: `src/LICENSES/hyperframes-Apache-2.0.txt`.
- The motion numbers come from the `motion-design` rules in claude-motion (MIT, whaleyxbt). License: `src/LICENSES/claude-motion-MIT.txt`.
- Fonts: Instrument Serif and Inter, SIL Open Font License (`fonts/OFL-*.txt`).
