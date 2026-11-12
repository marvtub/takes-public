# Cursor looks

## What it does

It draws the pointer of a screen recording in one of eight looks, over the edit. The look changes with what the pointer does:

| State | When |
|---|---|
| move | The normal arrow |
| hover | The screen showed the pointing hand (a link, a button) |
| text | The screen showed the I-beam (over text) |
| drag | The left button is held down while the pointer moves, or the screen showed the grab hand |
| wait | The `--wait` spans you give, or a cursor that keeps changing shape (the spinning wait) |

At each left click the look presses in and leaves a burst where it clicked.

| Look | `--look` | Colour by default |
|---|---|---|
| Glass: the Mac arrow, cleaned up, with a colour halo on hover | `glass` | `#FF5A36` |
| Comet: a dot with a short trail and rings on click | `comet` | `#FF5A36` |
| Ink: a black arrow with a hard colour shadow, a starburst on click, an hourglass while waiting | `ink` | `#FF5A36` |
| Caption: a colour arrow with a black label beside it (`--labels`) | `caption` | `#FF5A36` |
| Pointer stick: a 3D glove on a wooden stick that wiggles, pokes and taps | `stick` | `#FF5A36` (the cuff) |
| Pixel: a pixel-art arrow that moves in steps and bursts in blocks | `pixel` | `#FF5A36` |
| Plasma: a big glowing yellow ball that stretches as it moves and squishes on click | `plasma` | `#FFE600` |
| Glassmorph: a frosted white arrow and glass discs, for colourful screens | `glassmorph` | `#7C5CFF` |

The base pointer: the recipe's `pointer` must be `{"look": "none"}`, so `render_edit` does not draw the Mac arrow under the look.

Takes names the system cursors in the cursor log since 2026-10-31 (`"name"` on each shape). Older logs get a guess: a narrow, tall cursor is the I-beam, any other cursor than the arrow is the hand.

Use it only when the user asks for it. If the user did not say which look, ask, and show the eight names.

## What to change

| Value | What it controls |
|---|---|
| `--look` | One of the eight looks |
| `--accent` | The look's colour, `#RRGGBB` |
| `--scale` | The look's size: 1 is the size the Mac pointer had, 1.5 is half again as big |
| `--labels` | Caption look: `[{"at": edit s, "text": "Export the video", "len"?: s}]`, a chip beside the pointer (1.6 s by default) |
| `--wait` | `[[from, to, "Rendering"?]]` in edit seconds: the wait state (and for Caption a chip with a spinner) |
| `--raw` | Exactly the logged path. By default the path is eased, but exactly on the log near each click |
| `LOOKS` in `src/index.html` | Each look's markup per state, its press, burst and entrance, by hand |

**Each shape.** The pointer is placed through the same steps as `render_edit`, so it works for 9:16, 4:5, 1:1 and 16:9 and any `frame.crop`.

## How to make it for a video

1. The recipe's `cut` must show the screen take (`"kind": "screen"`). Get the cursor log path (`events`) and the take number from `get_session`. Get the edit's size `W` x `H` and any `frame.crop` from the recipe.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/cursor-looks/`.
3. In `_edit/<name>/`, run:

   ```
   python3 cursor-looks/cursor.py --events ../../take-NN-screen.events.json --take NN \
       --cut '<the recipe cut as JSON>' --size WxH --look plasma [--crop '<frame.crop as JSON>'] [--accent '#FFE600'] [--scale 1.2]
   ```

   It writes the path, the states and the clicks into `cursor-looks/index.html` and prints `{"at", "duration", "look", "clicks", "states"}`.
4. Add one step to the recipe. It renders the pointer with alpha (ProRes 4444):

   ```json
   "steps": [
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "cursor-looks", "--format", "mov", "-o", "cursor-looks.mov"],
      "makes": ["cursor-looks.mov"]}
   ]
   ```

5. Add the layer with the printed `at`: `"over": [{"file": "_edit/<name>/cursor-looks.mov", "at": <at>, "alpha": true}]`, and set `"pointer": {"look": "none"}`.
6. Run `render_edit`, then `check_edit`. Look at stills just after 2 clicks and over text: the look's tip must sit where the screen clicked.

When the cut changes, run step 3 again with the new cut.

With the recipe's `zoom` (effect screen-zoom), run step 3 as the recipe's first step instead, with `--zoom zoom.json`: the look moves and grows with the zoom.

With the click ring effect too, the two bursts double up: use one of them.

## Limits

- Needs a cursor log. Screen takes recorded before 2026-10-30 have none.
- Only screen takes whose video left the pointer out (`"pointer": false` in the log) can lose the Mac arrow. On older takes the recorded arrow stays under the look.
- Glassmorph's glass cannot blur the screen under it (the layer is drawn apart from the screen): it is frosted white, and it is hard to see on a white screen.
- The render needs Node.js (for `npx`), Chrome and ffmpeg. It loads GSAP and the Inter font from the network.

## Credits

- Made for Takes. Our own looks.
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0). Font: Inter (SIL OFL 1.1).
