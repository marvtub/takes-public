# Text behind

## What it does

The footage pulls back into a dark frame, and the background gets darker. A huge word or number rises up behind the speaker's head. A small accent line sits above it. The head stays in front of the word. Then the word sinks back down and the frame returns to full size.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `TEXT.word` | The big word. 1 to 5 characters reads best ("20K", "3X", "NO") |
| `TEXT.kicker` | The small accent line above the word |
| `LOOK.pull` | How far the footage pulls back. `1` = no pull back. Use `1` when the shot has room above the head |
| `LOOK.dim` | How dark the background gets behind the word (0 to 1) |
| `LOOK.size`, `LOOK.top` | The word size in px, and where the kicker starts (px from the top), both for a 1080x1920 frame. Other frames scale them |
| `LOOK.side`, `LOOK.end` | Wide frames only: the side of the head the word sits on (`left` or `right`), and where its inner end sits, as a part of the width from that side (`0.47` = just behind the head in a centred shot) |
| `AT` | When the pull back starts, when the word rises, when it leaves (seconds of `footage.mp4`) |
| `--accent` in `:root` | The colour of the kicker |
| `FRAME` | The frame size, read from `data-width` / `data-height` on `#root`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |

The video is as long as `footage.mp4`. Keep `AT.out` 0.8 s or more before its end.

The head must cover only the lower part of the word. Look at a frame, then move `LOOK.top` or change `LOOK.size` until the word reads.

The layout follows the frame:

- Tall and square (9:16, 4:5, 1:1): the word sits above the head, centred, and the head covers its lower part. 4:5 and 1:1 scale the word down with the frame.
- Wide (16:9): the word sits beside the head, as tall as in 9:16, vertically centred. Its inner end goes just behind the head; a long word gets smaller so it keeps 80 px from the edge. Set `LOOK.side` to the side with more room.

## How to make it for a video

The composition has three layers: the footage, the word, and the speaker cut out of the same footage. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (5 to 6 s is typical). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/text-behind/`.
3. Change `TEXT`, `LOOK` and `AT`.
4. Set `data-width` and `data-height` on `#root` to the edit's size. Add three steps to the recipe. The first step cuts the footage of the moment. The second step cuts the speaker out of it (the matte). The third step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>",
              "-vf", "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>",
              "-an", "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "text-behind/footage.mp4"],
      "makes": ["text-behind/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "remove-background", "text-behind/footage.mp4",
              "-o", "text-behind/person.webm", "--quality", "best"],
      "makes": ["text-behind/person.webm"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "text-behind", "-q", "delivery", "-o", "text-behind.mp4"],
      "makes": ["text-behind.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
5. Add the layer: `"over": [{"file": "_edit/<name>/text-behind.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
6. Run `render_edit`, then `check_edit`. Look at a frame in the middle of the effect. The word must be behind the head, and you must be able to read it.

The steps run on every render. The matte takes about 4 s for each second of footage on an Apple silicon Mac. To save time, run the first two commands once (as a job) and keep only the render step in the recipe.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9. The layout follows `data-width` / `data-height`; sizes are made for a 1080 px short side.
- It needs a head-and-shoulders shot with one person and a background that is clear of other people. The matte is made for people. It can miss things the person holds, and fine hair can get a soft edge.
- On a tight close-up the pull back makes the room for the word. With `LOOK.pull` at `1` the word needs free space above the head.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout. The idea (a headline behind the speaker) is a common technique.
- Cutout: `hyperframes remove-background` (HyperFrames, Apache-2.0). It runs on the Mac with no key. On the first run it downloads the `u2net_human_seg` model (176 MB, from the rembg project, MIT; U²-Net, Apache-2.0) to `~/.cache/hyperframes/background-removal/models/`.
- Fonts: Montserrat and Inter, SIL Open Font License 1.1 (`src/fonts/OFL-*.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
