# Click ring

## What it does

At each click in a screen recording, a soft white ring opens where the pointer clicked, then fades in about half a second. A light dot flashes under the click at the same time. A thin dark edge keeps the ring visible on light and dark screens. The pointer itself stays as it was recorded: the ring is a separate layer over the edit.

Each ring gets the sound of a real mouse click, press and release (`src/click.wav`). Use this file for screen clicks, not a click from the Sound FX bank: clicks made in code do not sound like a mouse to people.

The clicks come from the take's cursor log, `take-NN-screen.events.json`. Takes writes it next to the screen file while it records (screen takes from 2026-10-30 on). `get_session` shows it as `events` under the screen take. Without a cursor log this effect cannot be used.

Use it only when the user asks for it.

## What to change

`src/clicks.py` fills `CLICKS`, the size and `data-duration` on `#root`. Change the look in `LOOK` in `src/index.html` by hand:

| Value | What it controls |
|---|---|
| `LOOK.color` | The colour of the ring and the dot |
| `LOOK.shadow` | The thin dark edge and the soft shadow around the ring |
| `LOOK.grow` | Seconds the ring takes to open and fade |
| `LOOK.line` | The ring's line width at the start, as a share of its radius |
| `LOOK.dot` | `false` removes the dot under the click |
| `RADIUS` in `clicks.py` | The ring's full radius in px of the screen file (40 = 20 points on a 2x screen). It is scaled with the screen, never below `MIN_RADIUS` |
| `--buttons` | Which clicks get a ring: `left` (default), `right`, `other`, or a list such as `left,right` |
| `CLICK_GAIN` in `clicks.py` | The click sound's level in the mix, in dB (-7: clearly heard, under a voice) |

**Each shape.** The ring is drawn where the click lands in the edit's frame, so it works for 9:16, 4:5, 1:1 and 16:9 and any `frame.crop`. Clicks outside the part of the screen that the frame shows get no ring.

## How to make it for a video

1. The recipe's `cut` must show the screen take (`"kind": "screen"`). Get the cursor log path (`events`) and the take number from `get_session`. Get the edit's size `W` x `H` and any `frame.crop` from the recipe (`get_edit_recipe` for an existing edit).
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/click-ring/`.
3. In `_edit/<name>/`, run:

   ```
   python3 click-ring/clicks.py --events ../../take-NN-screen.events.json --take NN \
       --cut '<the recipe cut as JSON>' --size WxH [--crop '<frame.crop as JSON>']
   ```

   It maps each click through the same steps as `render_edit`: the cut part's place in the edit, `frame.crop`, then the scale that covers the frame and the centre cut. It writes the clicks into `click-ring/index.html` and prints `{"at", "duration", "rings", "sfx"}`. The layer starts 0.1 s before the first click and ends 0.8 s after the last. `sfx` has one entry per ring: `click.wav` placed so its press lands on the click. It takes the edit's name from the folder you run it in (`--name` to change it).
4. Add one step to the recipe. It renders the rings with alpha (ProRes 4444):

   ```json
   "steps": [
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "click-ring", "--format", "mov", "-o", "click-ring.mov"],
      "makes": ["click-ring.mov"]}
   ]
   ```

5. Add the layer with the printed `at`: `"over": [{"file": "_edit/<name>/click-ring.mov", "at": <at>, "alpha": true}]`, and add the printed `sfx` entries to the recipe's `sfx` (keep the sounds already there).
6. Run `render_edit`, then `check_edit`. Look at stills at 3 click times, about 0.1 s after each click: each ring must sit on the tip of the pointer.

When the cut changes, run step 3 again with the new cut: the rings and their sounds follow the cut times.

With the recipe's `zoom` (effect screen-zoom), run step 3 as the recipe's first step instead, with `--zoom zoom.json`: `render_edit` writes the zoomed view there before the steps, and each ring moves and grows with the zoom.

## Limits

- Needs a cursor log. Screen takes recorded before 2026-10-30 have none.
- The cut times are on the screen file's clock. A cut part from the camera file of the same take gets no rings.
- A window recording (one app window, not the whole display) is mapped to the window's place on screen, read 4 times a second. If the window was resized while recording, the rings can be off.
- The ring marks the click, not the pointer: when the pointer moves fast right after a click, the pointer leaves the ring.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own look. A ring at each click is a common technique in screen recordings.
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
- Click sound: "Mouse Click Sound" by Pixeliota, https://freesound.org/s/678248/ (CC0 1.0). Trimmed to the press and release and set to -1 dBFS peak.
