# Over the shoulder

## What it does

Two stat cards slide out from behind the speaker's head. Their numbers count up (for example to "377K"), then a small accent tag shows the change. The head stays in front of the cards. Then the cards slide back behind the head.

The frame never moves or scales. The footage stays full-bleed the whole time. Only a light vignette comes in at the edges, so the cards read.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `DATA` | The two cards. Each has `label`, `value` (counts up from 0, shows as 377K or 1.2M) and `delta` (the accent tag, `""` hides it) |
| `PLACE` | Where the cards go, by the shape of the frame: `tall` (9:16, 4:5), `square` (1:1) and `wide` (16:9). Each has `size` (`1` = full size, for a medium shot with room beside the head; about `0.7` for a close-up) and one entry per card: `side` (`left` or `right`), `x` (px from that side of the frame) and `y` (from the top, as a part of the frame height) |
| `LOOK.dim` | How dark the vignette at the edges gets (0 to 1). `0` = no vignette |
| `AT` | When the first card comes, the gap to the second card, how long the count takes, when the cards leave (seconds of `footage.mp4`) |
| `--accent` in `:root` | The colour of the tag |
| `FRAME` | The frame size, read from `data-width` / `data-height` on `#root`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |

The video is as long as `footage.mp4`. Keep `AT.out` 0.8 s or more before its end.

The head hides the inner part of each card. The text sits on the outer side, so it stays clear. Look at a frame in the middle. If the head covers a number, move that card out (`x`) or up (`y`), or make `LOOK.size` smaller. Keep `x` at 32 or more.

In a close-up, the head often leaves room on one side only. Then put both cards on that side, one above the other.

The layout follows the frame:

- Tall (9:16, 4:5): both cards on the left, one above the other, at size 0.7.
- Square (1:1): both cards on the left, a little smaller (0.62).
- Wide (16:9): one card on each side of the head, at size 0.85, the inner edge of each card just behind the head. The right card sits a little lower than the left one.

The frame never moves or scales in any format.

## How to make it for a video

The composition has three layers: the footage, the cards, and the speaker cut out of the same footage. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (5 to 6 s is typical). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/over-the-shoulder/`.
3. Set `data-width` and `data-height` on `#root` to the edit's size. Change `DATA`, `PLACE`, `LOOK` and `AT`. Measure the room beside the head on a frame of `footage.mp4` before you set the `PLACE` entry for this shape.
4. Add three steps to the recipe. The first step cuts the footage of the moment. The second step cuts the speaker out of it (the matte). The third step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>",
              "-vf", "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>",
              "-an", "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "over-the-shoulder/footage.mp4"],
      "makes": ["over-the-shoulder/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "remove-background", "over-the-shoulder/footage.mp4",
              "-o", "over-the-shoulder/person.webm", "--quality", "best"],
      "makes": ["over-the-shoulder/person.webm"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "over-the-shoulder", "-q", "delivery", "-o", "over-the-shoulder.mp4"],
      "makes": ["over-the-shoulder.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
5. Add the layer: `"over": [{"file": "_edit/<name>/over-the-shoulder.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
6. Run `render_edit`, then `check_edit`. Look at a frame in the middle of the effect. The cards must be behind the head, and you must be able to read both numbers.

The steps run on every render. The matte takes about 4 s for each second of footage on an Apple silicon Mac. To save time, run the first two commands once (as a job) and keep only the render step in the recipe.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9. The layout follows `data-width` / `data-height`; sizes are made for a 1080 px short side.
- It needs a head-and-shoulders shot with one person and a background that is clear of other people. The matte is made for people. It can miss things the person holds, and fine hair can get a soft edge.
- The footage does not pull back, so the cards need free space beside the head. A very tight close-up with the head across the full width has no room. Pick a wider moment.
- If the speaker moves a lot to one side, the head can cover a card. Move the card, or pick a calmer moment. In 16:9 the head sits between the cards, so a head that moves sideways covers one of them first.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout. The idea (proof cards behind the speaker) is a common technique.
- Cutout: `hyperframes remove-background` (HyperFrames, Apache-2.0). It runs on the Mac with no key. On the first run it downloads the `u2net_human_seg` model (176 MB, from the rembg project, MIT; U²-Net, Apache-2.0) to `~/.cache/hyperframes/background-removal/models/`.
- Fonts: Montserrat and Inter, SIL Open Font License 1.1 (`src/fonts/OFL-*.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
