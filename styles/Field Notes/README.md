# Field Notes style

The look for travel and on-location explainers: vertical footage with field-book paper on top of it. Typewriter place tags with coordinates, red marker notes written on the frame, torn paper strips with yellow highlighter, and a paper map with a dashed route and a taped polaroid. It should read like a reporter's notebook, not like a slide deck.

Ready-made parts are in `src/` (HyperFrames compositions, 1080×1920). Each one has its text and timings at the top of its script. Change those, then render. The rendered examples are in `assets/Motion/`.

| Part | File | Use |
|---|---|---|
| Title card | `src/title-card/index.html` | The hook or a chapter: a typewriter headline on paper, one marker note |
| Lower third | `src/lower-third/index.html` | The place tag (coordinates + place name) and one marker note, the first time a new place is on screen |
| Captions | `src/captions/index.html` | One phrase at a time on a torn paper strip, highlighter on the key words |
| Figure page | `src/figure/index.html` | A map: route from A to B, one distance or time, a polaroid from the footage |

## Colour

- Paper `paper` for full pages, `tag` for tags and strips on footage. Both carry paper grain. Grain goes on paper only, never on the person.
- Text in `ink`. Coordinates and datelines in `muted`.
- Two marks, each with one job:
  - `marker` (red) is the hand: notes, the route, the pins. Never for body text.
  - `highlighter` (yellow) is the key words of a line. One run per line at most. If every word is yellow, none is.
- Map: `land` fill, `coast` lines, `grid` at half opacity.

## Type

- Courier Prime Bold for everything typed: headlines, captions, place names, map labels. Courier Prime Regular for coordinates and datelines.
- Caveat Brush in capitals for everything handwritten: marker notes and the polaroid caption.
- Typed text is straight. Handwritten text and paper are tilted (2–6°). Never tilt typed text inside a straight block.
- Captions: Courier Prime Bold, 52 px on a 1080-wide frame, sentence case, one phrase at a time (28 characters or fewer).
- Marker notes: two lines at most, 16 characters or fewer each.
- Phone test: at 360 px wide every caption and tag must still read.

## Captions

- On a torn `tag` strip, 60 px from the left edge, top at 1500 px: below the face, above the app buttons. The strip fits its phrase.
- Karaoke: each word goes from 35% to 100% opacity as it is spoken. Mark key words with `*`: the highlighter sweeps over them as they are said.
- The strip slaps on in 0.16 s and cuts out. No captions on paper pages (the page is the line).

## Placement on footage

- The tag goes top left (70 px, 150 px). The marker note goes in the sky or the background, never across the eyes or the mouth, and never on dark clothing or hair, where red does not read.
- Footage is full frame. Paper pages cut in full frame too.

## Map page

- A typewriter headline at the top with the number highlighted.
- Coastlines as simple hand-drawn shapes. A faint grid. No real map tiles.
- Start pin small, end pin larger with a white ring. The end place gets the ink label; the start place gets plain type.
- The route is dashed and draws from A to B. The marker note sits next to the route, not on it.
- A polaroid with the footage, tilted 5°, with tape and a marker caption.

## Motion

The numbers are in `tokens.json` under `motion`.

- **Entrances** ease out (`ease-out`). **Exits** ease in, and take about half as long as the entrance.
- **Typewriter:** headlines type on letter by letter, 0.035 s a letter, each letter whole (no fade). Then the highlighter sweeps over the marked words.
- **Marker:** a note writes itself on, left to right, 0.55 s a line.
- **Paper:** tags and polaroids drop on and settle to their tilt (0.4 s). Strips slap on (0.16 s).
- **Pages:** hard cuts in and out. Only the route, the note and the polaroid move on the map page.
- **Hold** every line you want read: at least 1 s for a short phrase, plus 0.25 s for each word after three. Text never moves while it is read.
- **Never:** zooms, push-ins, tilts or film grain on the footage, wipes, flashes, linear easing on anything that starts or stops, two things moving for attention at once, text within 60 px of the frame edge, a black first frame, red marker over a face.

## Credits

- The lower third and title card start from HyperFrames blocks `lt-side-rule` and `titlecard-calm` (Apache-2.0, HeyGen), changed for this style. License: `src/LICENSES/hyperframes-Apache-2.0.txt`.
- The motion numbers come from the `motion-design` rules in claude-motion (MIT, whaleyxbt). License: `src/LICENSES/claude-motion-MIT.txt`.
- Fonts: Courier Prime and Caveat Brush, SIL Open Font License (`fonts/OFL-*.txt`).
