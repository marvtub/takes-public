# Bold Captions style

The look for fast vertical talking videos (Shorts, Reels, TikTok): big all-caps captions with a thick black stroke, one or two key words in colour, white label boxes for titles, and a navy studio. Everything pops. It should feel loud and quick, but you must always be able to read it.

Ready-made parts are in `src/` (HyperFrames compositions, 1080×1920). Each one has its text and timings at the top of its script. Change those, then render. The rendered examples are in `assets/Motion/`.

| Part | File | Use |
|---|---|---|
| Title card | `src/title-card/index.html` | The hook or a chapter: a white label box at the top, over the footage |
| Lower third | `src/lower-third/index.html` | Your name in a white box and one line in a yellow tag, the first time you are on screen |
| Captions | `src/captions/index.html` | Every spoken word, popping in on time, key words in colour |
| Figure | `src/figure/index.html` | One comparison on a navy card: thick bars, big numbers, a punchline |

## Colour

- Studio `navy` behind the speaker and on figure cards. A figure card has a soft lighter centre.
- Caption text is `caption` (white) with a 16 px `stroke` (black) and a hard 10 px black drop shadow.
- Two accents: `hot` (yellow) for the key word, `win` (green) for numbers and wins. Use one or two coloured words per phrase. If every word is yellow, no word is.
- Label boxes are white with black text and a soft shadow.

## Type

- Montserrat 900, all caps, for captions, label boxes and numbers. Montserrat 800 for small tags.
- Captions: 98 px on a 1080-wide frame, line height 1.04, letter spacing −1 px, centred.
- Label boxes: 64 px, two lines at most.
- Phone test: at 360 px wide every caption must still read.

## Captions

- At most two lines of 14 characters or fewer. A phrase ends at . , ? ! or when a third line would start.
- The block sits under the face and over the hands (top at 1150 px). Never on the face. Never in the bottom 300 px, where the app puts its buttons.
- Each word pops in on its spoken time (scale 0.6 to 1, overshoot). The whole phrase cuts out when the next one starts.
- Mark the key word in `WORDS` with `"y"` (yellow) or `"g"` (green).
- Captions keep running under a title label box. No captions on a figure card (the card is the line).

## Motion

The numbers are in `tokens.json` under `motion`.

- **Entrances** pop: scale up from 0.6 with a small overshoot (`back.out`), 0.16 s for a word, 0.25 s for a box or row.
- **Exits** are fast (0.12 s, `ease-in`) or a hard cut.
- **Footage to card:** hard cut. The card cuts in with its title already on screen.
- **Hold** every phrase you want read: at least 0.5 s plus 0.3 s for each word.
- **Never:** wipes, slides, flashes, fake zooms or shakes on the footage, light leaks or grain on the person, more than two coloured words in one phrase, text on the face, text within 60 px of the frame edge or in the bottom 300 px, a black first frame.

## Credits

- The lower third and title card start from HyperFrames blocks `lt-side-rule` and `titlecard-calm` (Apache-2.0, HeyGen), changed for this style. License: `src/LICENSES/hyperframes-Apache-2.0.txt`.
- The motion rules (exits half an entrance, hold times) come from the `motion-design` rules in claude-motion (MIT, whaleyxbt). License: `src/LICENSES/claude-motion-MIT.txt`.
- Font: Montserrat (variable), SIL Open Font License (`fonts/OFL-Montserrat.txt`).
