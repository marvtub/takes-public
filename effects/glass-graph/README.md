# Glass graph

## What it does

A frosted-glass card comes up in the lower third. It shows a label, a big number that counts up, and five bars that grow one after the other. The tallest bar is in the warm accent. The footage behind the card is blurred, like frosted glass. The card stays on screen, then leaves.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `data-width`, `data-height` | The size of the edit in px, on `#root`. 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) and 1920x1080 (16:9) all work. The layout follows the shape (see below) |
| `TEXT.label` | The small label, top left of the card |
| `DATA.total` | The number that counts up |
| `DATA.bars` | Five `[name, value]` pairs. Bar height is relative to the largest value |
| `AT` | When the card enters, how long the count takes, when the bars grow, when the card leaves (seconds) |
| `data-duration` | The length of the effect, on `#root` and on the `<video>` (seconds). Keep `AT.out` 0.3 s or more before the end |
| `BOTTOM` | The space under the card (px), per shape: `tall` (9:16), `"4:5"`, `square` (1:1), `wide` (16:9) |
| `--accent`, `--glass` in `:root` | The accent colour and the tint of the glass |

Keep bar names short (one word, 9 letters or fewer).

**Each shape.** 9:16: the tall card in the lower third, 300 px from the bottom. 4:5, 1:1 and 16:9: a shorter card (912x390 px, lower bars, 32 px labels) centred near the bottom, so it stays under the chin.

## How to make it for a video

The composition needs the footage of the moment, because the glass blurs it. The render is a full-frame layer: footage and card together.

1. Pick the cut time `T` where the card starts and its length `D` (6 s is typical). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/glass-graph/`.
3. Change `TEXT`, `DATA` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size `W` x `H`. Set `data-duration` to `D` on `#root` and on the `<video>`.
4. Add two steps to the recipe. The first step cuts the footage of the moment. The second step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>",
              "-vf", "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1",
              "-an", "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "glass-graph/footage.mp4"],
      "makes": ["glass-graph/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "glass-graph", "-q", "delivery", "-o", "glass-graph.mp4"],
      "makes": ["glass-graph.mp4"]}
   ]
   ```

   `<W>` and `<H>` are the edit's size. `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
5. Add the layer: `"over": [{"file": "_edit/<name>/glass-graph.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
6. Run `render_edit`, then `check_edit`. Look at a frame in the middle of the effect.

### Without the footage (alpha layer)

You can also render only the card. Delete the `<video>` line, set `--glass` to `rgba(18, 18, 22, 0.75)`, and render with `--format mov -o glass-graph.mov`. Then use `{"file": "_edit/<name>/glass-graph.mov", "at": T, "alpha": true}`. The card then has a dark tint but no blur.

## Limits

- Made for 9:16, 4:5, 1:1 and 16:9. Other sizes use the layout of the nearest shape.
- In 1:1 and 16:9 the card covers the chest. If the speaker sits low in the frame, make `BOTTOM` smaller or the effect shorter.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect, or make `footage.mp4` from both entries.
- The count runs from 0 up. The number shows with commas (en-US).
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout. The idea (a glass stat card over a talking head) is a common technique.
- Font: Inter, SIL Open Font License 1.1 (`src/fonts/OFL-Inter.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
