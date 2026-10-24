# Clean Studio style

The look for calm, friendly vertical videos (1080×1920): bright daylight footage, serif titles on white rounded panels, caption pills, and pastel cards. It should feel like a tidy, sunny studio, not like an ad.

Ready-made parts are in `src/` (HyperFrames compositions). Each one has its text and timings at the top of its script. Change those, then render. The rendered examples are in `assets/Motion/`.

| Part | File | Use |
|---|---|---|
| Title card | `src/title-card/index.html` | The hook: one line on a white panel above the head |
| Lower third | `src/lower-third/index.html` | Your name and one line, the first time you are on screen |
| Captions | `src/captions/index.html` | One phrase at a time in a white pill, karaoke on the spoken word |
| Figure page | `src/figure/index.html` | Two to four ideas as pastel cards, with the speaker in a small frame |

## Colour

- Panels and pills are white at 92–94% (`panel`) with a soft shadow. Text in `ink`.
- One accent: `accent` (rose). Use it for the one italic word of a headline, and nothing else in the text. If every word is rose, nothing stands out.
- One gold sparkle (`spark`) beside a title or a name. One per frame, never on text.
- Pastel pages use the warm gradient `page-top` → `page-mid` → `page-bottom` at 160°.
- Cards use `sky`, `rose`, `mint` (and `sun` for a fourth). White text on the cards.

## Type

- Fraunces 600 for titles, names and card labels. Put one word of a headline in Fraunces italic 500, in `accent`: "One rule for a *calm* week".
- Inter 600 for captions and card numbers. Inter 500 for the second line of a lower third.
- Captions: Inter 600, 52 px on a 1080-wide frame, sentence case, centred, one phrase at a time (24 characters or fewer).
- Captions are sans and the titles are serif, so a caption never looks like a title.
- Phone test: at 360 px wide the title must still read.

## Captions

- A white pill under the face (top at 1460 px on footage, 1300 px on a pastel page).
- Karaoke: each word goes from `soon` (grey) to `ink` as it is spoken. No highlight box, no colour.
- The pill rises 16 px as it fades in, and fades out fast before the next phrase.

## Layout

- The face stays clear. Titles sit above the head (top 190 px), names and captions sit on the chest.
- Panels keep 70 px from the side edges. All text stays 60 px or more from every edge.
- On a pastel page the headline sits at the top, the cards in the middle, and the speaker in a 300×380 frame at the bottom right (40 px corners, 8 px white border).

## Motion

The numbers are in `tokens.json` under `motion`.

- **Entrances** ease out (`ease-out`). **Exits** ease in, and take about half as long as the entrance.
- **Words** arrive one by one, 0.08 s apart, rising 18–24 px. No blur.
- **Panels** rise 24 px and grow from 97% to full size in 0.5 s.
- **Cards** rise one by one, 0.22 s apart, and settle into their tilt (±6°). The middle card sits 30 px higher.
- **The sparkle** pops in last, with a small overshoot (`back.out(2)`).
- **Footage to page:** a hard cut.
- **Hold** every line you want read: at least 1 s for a short phrase, plus 0.25 s for each word after three. Text never moves while it is read.
- **Never:** zooms or push-ins on the person, tilts, light leaks, film grain, wipes, flashes, linear easing on anything that starts or stops, two things moving for attention at once, text over the face, text within 60 px of the frame edge, a black first frame.

## Credits

- The lower third and title card start from HyperFrames blocks `lt-side-rule` and `titlecard-calm` (Apache-2.0, HeyGen), changed for this style. License: `src/LICENSES/hyperframes-Apache-2.0.txt`.
- The motion numbers come from the `motion-design` rules in claude-motion (MIT, whaleyxbt). License: `src/LICENSES/claude-motion-MIT.txt`.
- Fonts: Fraunces and Inter, SIL Open Font License (`fonts/OFL-*.txt`). Fraunces ships as its variable font (the only form in the Google Fonts repository).
