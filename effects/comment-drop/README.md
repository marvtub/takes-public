# Comment drop

## What it does

An empty comment box drops in near the top. A big keyword drops in above it, letter by letter, with a bounce. Then the letters fall into the box, one after another, and type themselves. The Post button turns green and is pressed. The box becomes the pinned comment: "KEYWORD to get ...", with the user's photo and handle. A viewer's reply with just the keyword drops in under it. Hearts fill and the like count ticks up. Sticker captions pop in and stack up near the speaker's hands. The shot moves down a little to make room. Then it all lifts away.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `CTA.word` | The keyword. 3 to 6 capital letters read best |
| `CTA.handle` | The handle on the pinned comment. Set it to the user's handle |
| `CTA.rest` | The rest of the pinned comment, after the keyword |
| `CTA.likes` | How many likes the pinned comment ticks up to |
| `CAPTIONS` | The sticker captions: `[text, when it shows (seconds)]`. The keyword in the first one turns green |
| `PLACE.y`, `PLACE.w` | The top and width of the comment stack, as parts of the frame. It is centred |
| `PLACE.capTop` | The top of the captions, as a part of the frame height |
| `PLACE.gap` | The gap between the two comments. All sizes are px for a 1080 px short side. Other frames scale them. |
| `PLACE.down` | How far the shot moves down to make room above the head, as a part of the height (0 = not at all). The gap at the top is filled with the top of the shot, mirrored |
| `LOOK` | The colours (`green`, `cream`, `red` hearts) and the size of the big letters (`big`, px at 1080) |
| `AT` | When the letters drop (`drop`), fall into the box (`fall`), it posts (`post`), the reply drops (`reply`), it all leaves (`out`), in seconds |
| `data-width`, `data-height` | The frame size, on `#root`. The script reads it as `FRAME`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |
| `data-duration` | The length of the effect in seconds, on `#root` (4.4 s now). The times in `AT` are seconds from its start |

The layout follows the frame:

- Tall and square (9:16, 4:5, 1:1): the stack is centred near the top, and the shot moves down by `PLACE.down`.
- Wide (16:9): set `PLACE.w` to about 0.45 and `PLACE.down` to 0.

Layout by frame shape: Square and wide frames (1:1, 16:9) lay themselves out: the comment stack goes top left beside the head, the cards get a little smaller in a square, the shot does not move down, and the big letters stay inside the frame. Tall frames (9:16, 4:5) use `PLACE` as set.

## How to make it for a video

The composition has the footage and the comment cards on top. It needs no cutout, only a round photo of the speaker. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (4.4 s now; keep the times in `AT` inside it). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/comment-drop/`.
3. Change `CTA`, `CAPTIONS`, `PLACE`, `LOOK` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Make `comment-drop/avatar.png` once: a square photo of the speaker's face, about 320x320 (the page shows it round). Use the user's profile photo if they have one. Else cut it from a frame of the take: `ffmpeg -y -ss <take time> -i ../../<take file> -frames:v 1 -vf "crop=<S>:<S>:<x>:<y>,scale=320:320" comment-drop/avatar.png`, with the face in the middle of the square.
5. Add two steps to the recipe. The first step cuts the footage of the moment. The second step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>", "-vf",
              "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>", "-an",
              "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "comment-drop/footage.mp4"],
      "makes": ["comment-drop/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "comment-drop", "-q", "delivery", "-o",
              "comment-drop.mp4"],
      "makes": ["comment-drop.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
6. Add the layer: `"over": [{"file": "_edit/<name>/comment-drop.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
7. Run `render_edit`, then `check_edit`. Look at a frame after the reply lands. The keyword must read, the cards must not cover the face, and the captions must not cover the mouth.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9 (see the layout above).
- The captions are part of this effect. Turn off the edit's own captions while it runs, or they clash.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion.
- Font: Inter, SIL Open Font License 1.1 (`src/fonts/OFL-Inter.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
