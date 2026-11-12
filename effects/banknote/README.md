# Banknote

## What it does

A hard cut to a banknote that fills the frame. The speaker is the engraved portrait in the oval, still talking. The portrait is drawn in fine green wavy lines that get thicker where the picture is dark, like money engraving. The room behind the speaker prints light. A guilloche border, a rope round the oval and a rosette seal frame it. A big number types itself in digit by digit, and the four corner numbers follow it. Under it are a title line, the seal with a name, a red serial and two lines of fine print. Then a hard cut back.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `NOTE.number` | The big number, typed digit by digit. Up to about 8 characters fit |
| `NOTE.words` | The same number in words. It runs round the oval as microtext |
| `NOTE.title` | The title line under the number (and in the microtext) |
| `NOTE.name`, `NOTE.role` | The two name lines and the role on the seal |
| `NOTE.serial`, `NOTE.fine` | The red serial at the top, and the two lines of fine print at the bottom |
| `PORTRAIT` | The part of the footage that becomes the portrait: centre `x`, centre `y`, `w`, `h`, as parts of the frame. Head and shoulders. `engrave.py` reads this line: keep it on one line, and run `engrave.py` again after a change |
| `LOOK.paper`, `LOOK.ink`, `LOOK.deep`, `LOOK.red` | The paper, the light ink, the deep ink (portrait and type) and the serial colour |
| `LOOK.lineW` | How thick the engraving lines get in the darks (1 = normal) |
| `AT` | The cut to the note (`in`), when the number starts (`type`), the time per character (`every`) and the cut back (`out`), in seconds |
| `data-width`, `data-height` | The frame size, on `#root`. The script reads it as `FRAME`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |
| `data-duration` | The length of the effect in seconds, on `#root` (3 s now). The times in `AT` are seconds from its start |

In `src/engrave.py`, at the top, and on its command line (`python3 engrave.py <folder> [seconds] [lines] [cols] [fps]`):

| Value | What it controls |
|---|---|
| `ROOM` | How dark the room behind the speaker prints (0 = ink, 1 = paper) |
| `CONTRAST` | How much contrast the face gets |
| `seconds` | How much of the footage it reads. Use `D` |
| `lines`, `cols` | The engraving grid: lines down the oval and samples on each line (150 and 260) |
| `fps` | Portrait frames a second (15) |

Change every value in `NOTE` for the video. The values in the file are only an example.

`engrave.py` takes the levels from the face and evens out side light first, so both halves of the face read.

The layout follows the frame:

- 9:16: the sheet fills the frame.
- 4:5, 1:1 and 16:9: the sheet keeps its 9:16 shape, as big as fits, and stands in the middle on a dark ground.

## How to make it for a video

The composition has the footage and the note on top. `engrave.py` samples the portrait from the footage and the speaker's matte, 15 times a second, and writes `lum.js`. The page draws the engraving lines from it every frame. The border, rope and seal are drawn with maths on a canvas. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (3 s now; keep the times in `AT` inside it). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/banknote/`.
3. Change `NOTE`, `PORTRAIT`, `LOOK` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Add four steps to the recipe. The first step cuts the footage of the moment. The second step cuts the speaker out of it (the matte). The third step makes the engraving data. The fourth step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>", "-vf",
              "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>", "-an",
              "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "banknote/footage.mp4"],
      "makes": ["banknote/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "remove-background", "banknote/footage.mp4", "-o",
              "banknote/person.webm", "--quality", "best"],
      "makes": ["banknote/person.webm"]},
     {"run": ["python3", "banknote/engrave.py", "banknote", "<D>", "150", "260"],
      "makes": ["banknote/lum.js"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "banknote", "-q", "delivery", "-o",
              "banknote.mp4"],
      "makes": ["banknote.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
5. Add the layer: `"over": [{"file": "_edit/<name>/banknote.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
6. Run `render_edit`, then `check_edit`. Look at a frame after the number is in. The face must read in the oval, with dark eyes and a light room, and the number must fit its box.

The steps run on every render. The matte takes about 4 s for each second of footage on an Apple silicon Mac. To save time, run the steps before the render once (as a job) and keep only the render step in the recipe.

## Limits

- Made for 9:16. In other shapes the note stands in the middle (see the layout above).
- It needs a shot with one person and a background that is clear of other people. The matte is made for people. It can miss things the person holds, and fine hair can get a soft edge.
- `engrave.py` needs Python 3 with numpy and OpenCV (`cv2`). `lum.js` is about 2.3 MB for 3 s.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion.
- Cutout: `hyperframes remove-background` (HyperFrames, Apache-2.0). It runs on the Mac with no key. On the first run it downloads the `u2net_human_seg` model (176 MB, from the rembg project, MIT; U²-Net, Apache-2.0) to `~/.cache/hyperframes/background-removal/models/`.
- The guilloche, rope and rosette are our own, drawn in code.
- Fonts: Old Standard TT and Oswald, SIL Open Font License 1.1 (`src/fonts/OFL-*.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
