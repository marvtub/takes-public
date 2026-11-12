# Predict keys

## What it does

A phone keyboard pops up from below with a small tilt. A text bar sits on top with some text in it. The keyboard types a word, one letter at a time: each tapped key flashes and pops a bigger copy above it. The three suggestions above the keys change with every letter. The last tap hits a suggestion. The word jumps into the text bar in gold, the send button turns gold, and the suggestions change to guesses for the next word. Then the keyboard drops away down and to the right.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `TEXT.lead` | The text in the bar before the word |
| `TEXT.word` | The word that is picked from the suggestions. It shows in gold |
| `STEPS` | Each tap: `key` (a lower-case letter a to z) and `sug` (the three suggestions shown after it). The first entry has `key: null`: the suggestions before the first tap |
| `PICK` | Which suggestion the last tap hits (0, 1 or 2). Put `TEXT.word` in that place in the last `sug` |
| `NEXT` | The three next-word guesses after the pick |
| `PLACE.bottom` | Where the keyboard's bottom edge sits, as a part of the frame height |
| `PLACE.width` | The keyboard width, as a part of the frame's short side. In 16:9 use about 0.75 |
| `LOOK` | The colours: `green` (bar and function keys), `cream` (keys), `gold` (the picked word and send) |
| `AT` | When the keyboard comes in (`in`), the first tap (`tap`), the time between taps (`every`) and when it goes (`out`), in seconds |
| `data-width`, `data-height` | The frame size, on `#root`. The script reads it as `FRAME`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |
| `data-duration` | The length of the effect in seconds, on `#root` (3.6 s now). The times in `AT` are seconds from its start |

Keep `AT.out` at least 0.4 s after the last tap. The last tap is at `AT.tap + (taps - 1) * AT.every`. Each extra letter needs `AT.every` more time.

The text is set from the time on every frame, so the render is the same in any seek order.

The layout follows the frame:

- The keyboard is centred, and its width comes from the short side. In 16:9 it sits in the middle, over the speaker's body: set `PLACE.bottom` so it does not cover the face.

## How to make it for a video

The composition has the footage and the keyboard on top. It needs no cutout. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (3.6 s now; keep the times in `AT` inside it). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/predict-keys/`.
3. Change `TEXT`, `STEPS`, `PICK`, `NEXT`, `PLACE`, `LOOK` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Add two steps to the recipe. The first step cuts the footage of the moment. The second step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>", "-vf",
              "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>", "-an",
              "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "predict-keys/footage.mp4"],
      "makes": ["predict-keys/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "predict-keys", "-q", "delivery", "-o",
              "predict-keys.mp4"],
      "makes": ["predict-keys.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
5. Add the layer: `"over": [{"file": "_edit/<name>/predict-keys.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
6. Run `render_edit`, then `check_edit`. Look at a frame just after the pick. The word must be gold in the bar, and the keyboard must not cover the face.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9.
- `STEPS` keys must be lower-case letters a to z. Other keys are not on the keyboard, and the page stops.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion.
- Font: Inter, SIL Open Font License 1.1 (`src/fonts/OFL-Inter.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
