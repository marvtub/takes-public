# Voice note

## What it does

A chat voice message pops in near the top, beside the speaker's round photo. Its waveform records in from the left, bar by bar, with a gold line at the recording edge. The bars come from what the speaker says in that moment. A label types in under the message. The send button is pressed with a ripple, and "Delivered ✓" ticks on. Then the message flies off up and away.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `LABEL` | The label that types in under the message |
| `PLACE.x`, `PLACE.y` | The message's left edge and top, as parts of the frame |
| `LOOK` | The colours: `cream` (bubble), `green` (play button and recorded bars), `gold` (edge and send), `light` (bars still to record) |
| `AT` | Pop in (`in`), the recording starts (`rec`) and runs (`recFor`), the label types (`label`), send is pressed (`send`), delivered (`done`), fly off (`out`), in seconds |
| `data-width`, `data-height` | The frame size, on `#root`. The script reads it as `FRAME`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |
| `data-duration` | The length of the effect in seconds, on `#root` (3 s now). The times in `AT` are seconds from its start |

`wave.py` takes its values on the command line: `python3 wave.py <audio or video> <start> <length> <out> [bars]`:

| Value | What it controls |
|---|---|
| `<audio or video>` | The take file. Its sound gives the bars |
| `<start>`, `<length>` | The take time of the moment and `D`, in seconds |
| `[bars]` | How many bars. Use 26: the bubble is made for 26 |

The layout follows the frame:

- The bubble is about 690 px wide for a 1080 px short side, in every shape. In 16:9 it sits at the left: move it with `PLACE.x` if the face is there.

Layout by frame shape: Square and wide frames move the message down over the chest (`PLACE.y` 0.62 or more), because the head fills the top of those shots.

## How to make it for a video

The composition has the footage and the message on top. It needs no cutout, only a round photo of the speaker and the loudness of the voice. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (3 s now; keep the times in `AT` inside it). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/voice-note/`.
3. Change `LABEL`, `PLACE`, `LOOK` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Make `voice-note/avatar.png` once: a square photo of the speaker's face, about 320x320 (the page shows it round). Use the user's profile photo if they have one. Else cut it from a frame of the take: `ffmpeg -y -ss <take time> -i ../../<take file> -frames:v 1 -vf "crop=<S>:<S>:<x>:<y>,scale=320:320" voice-note/avatar.png`, with the face in the middle of the square.
5. Add three steps to the recipe. The first step cuts the footage of the moment. The second step reads the loudness of the voice for the bars. The third step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>", "-vf",
              "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>", "-an",
              "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "voice-note/footage.mp4"],
      "makes": ["voice-note/footage.mp4"]},
     {"run": ["python3", "voice-note/wave.py", "../../<take file>", "<take time>", "<D>",
              "voice-note/wave.js", "26"],
      "makes": ["voice-note/wave.js"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "voice-note", "-q", "delivery", "-o",
              "voice-note.mp4"],
      "makes": ["voice-note.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
6. Add the layer: `"over": [{"file": "_edit/<name>/voice-note.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
7. Run `render_edit`, then `check_edit`. Look at a frame after "Delivered". The message must not cover the face, and the bars must go up and down with the voice.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9.
- `wave.py` needs Python 3 with numpy.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion.
- Font: Inter, SIL Open Font License 1.1 (`src/fonts/OFL-Inter.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
