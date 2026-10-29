# Tier list

## What it does

A dark board with five rows (S, A, B, C, D) comes up in the lower half. Tiles drop into their rows one by one. A chip above the board says "Ranking tools…" with a small spinner. When the last tile lands, the chip changes to "Ranked" with a green dot. Then the board leaves.

The layer is transparent. It goes over the footage as an alpha layer.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `data-width`, `data-height` | The size of the edit in px, on `#root`. 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) and 1920x1080 (16:9) all work. The layout follows the shape (see below) |
| `TEXT.busy`, `TEXT.done` | The chip text before and after |
| `TIERS` | Row names and colours |
| `ITEMS` | The tiles, in the order they drop: `{mark, color, tier}` |
| `AT` | When the board enters, the first drop, the time between drops, when the board leaves (seconds) |
| `data-duration` | The length of the effect, on `#root` (seconds) |
| `PLACE.bottom` | The space under the board (px), per shape: `tall` (9:16), `"4:5"`, `square` (1:1), `wide` (16:9). Make it larger to move the board up |
| `PLACE.side` | 16:9 only: `"left"` or `"right"`, the side of the frame for the board. Pick the side away from the face |

`mark` is one or two letters (`"Nx"`) or a shape: `circle`, `square`, `triangle`, `diamond`, `star`. Use a dark `color` so white marks stay easy to read. A row holds up to 8 tiles.

**Each shape.** 9:16: the tall board in the lower half. 4:5 and 1:1: a shorter board (66 px rows, 32 px chip and letters) near the bottom. 16:9: the short board, 700 px wide, on one side (`PLACE.side`).

Do not use real brand logos unless the user has the right to use them. Letters and shapes are safe.

Keep `AT.out` at least 2 s after the last drop (`AT.first + (number of items − 1) × AT.every`), so "Ranked" can be read.

## How to make it for a video

1. Pick the cut time `T` where the board starts and its length `D` (6 s is typical).
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/tier-list/`.
3. Change `TEXT`, `ITEMS`, `PLACE` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Add one step to the recipe. It renders the board with alpha (ProRes 4444):

   ```json
   "steps": [
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "tier-list", "--format", "mov", "-o", "tier-list.mov"],
      "makes": ["tier-list.mov"]}
   ]
   ```

5. Add the layer: `"over": [{"file": "_edit/<name>/tier-list.mov", "at": T, "alpha": true}]`.
6. Run `render_edit`, then `check_edit`. Look at a frame after the last drop.

The layer does not need the footage, so it can cross cut points.

## Limits

- Made for 9:16, 4:5, 1:1 and 16:9. Other sizes use the layout of the nearest shape.
- Five rows. To add or remove a row, change `TIERS` and check that the board still fits above `PLACE.bottom`.
- The board covers the lower half (in 1:1 it reaches the chin). Captions in the same place will clash: move them or pause them.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout, colours and tile marks. A tier list is a common format.
- Font: Inter, SIL Open Font License 1.1 (`src/fonts/OFL-Inter.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
