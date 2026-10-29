# Checklist

## What it does

A dark card comes up in the lower third with a title, for example "3 things before you post". A count by the title says "0/3". Each line comes in as the speaker says it, and the card grows to make room. A moment later the line's box fills green, a check draws in, and the text dims with a thin strike. The count goes up. When all lines are done, the count turns green. Then the card leaves.

The layer is transparent. It goes over the footage as an alpha layer.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `data-width`, `data-height` | The size of the edit in px, on `#root`. 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) and 1920x1080 (16:9) all work. The layout follows the shape (see below) |
| `TEXT.title` | The title line |
| `ITEMS` | The lines, in order: `{text, at}`. `at` is when the line comes in (seconds from the start of the effect) |
| `LOOK.position` | `"lower"` (lower third, grows up) or `"top"` (top of the frame, grows down) |
| `LOOK.offset` | The space from the bottom (or top) edge, in px, per shape: `tall` (9:16), `"4:5"`, `square` (1:1), `wide` (16:9) |
| `LOOK.side` | 16:9 only: `"left"` or `"right"`, the side of the frame for the card. Pick the side away from the face |
| `LOOK.accent` | The colour of the filled boxes and the final count |
| `LOOK.strike`, `LOOK.dim` | A thin line through done text, and done text in a muted colour |
| `AT` | When the card enters, the time from a line coming in to its tick, the exit (seconds) |
| `data-duration` | The length of the effect, on `#root` (seconds) |

Use 3 to 5 lines. Keep each line short: about 24 characters fit on one line. A longer line wraps to two lines.

Set each `at` to the time the speaker starts to say that line. Read the times from the take's words (`get_session` edit_ready), minus `T`. Keep `AT.out` at least 1 s after the last tick (`last at + AT.tick`).

**Each shape.** 9:16, 4:5 and 1:1: the card spans the width (84 px from each side), 260, 120 or 48 px from the bottom. 16:9: a 760 px card on one side (`LOOK.side`), 48 px from the bottom. Outside 9:16 the count is 32 px.

`"top"` covers the hair and forehead in a normal talking-head frame. Use it only when the lower third is busy (captions, a product, hands).

## How to make it for a video

1. Pick the cut time `T` where the card starts and its length `D`. The card must stay until the last line is ticked. 6 s fits three lines; add about 1.2 s for each extra line.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/checklist/`.
3. Change `TEXT`, `ITEMS`, `LOOK` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Add one step to the recipe. It renders the card with alpha (ProRes 4444):

   ```json
   "steps": [
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "checklist", "--format", "mov", "-o", "checklist.mov"],
      "makes": ["checklist.mov"]}
   ]
   ```

5. Add the layer: `"over": [{"file": "_edit/<name>/checklist.mov", "at": T, "alpha": true}]`.
6. Run `render_edit`, then `check_edit`. Look at a frame after the last tick. Each line must come in with the words.

The layer does not need the footage, so it can cross cut points.

## Limits

- Made for 9:16, 4:5, 1:1 and 16:9. Other sizes use the layout of the nearest shape.
- In 16:9 the card is 760 px wide on one side. It suits a speaker in the middle or on the other side.
- 3 to 5 lines. More lines make the card cover the face.
- The card covers the lower third. Captions in the same place will clash: move them or pause them.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion. A ticked checklist is a common format.
- Font: Inter, SIL Open Font License 1.1 (`src/fonts/OFL-Inter.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
