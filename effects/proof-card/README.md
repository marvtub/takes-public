# Proof card

## What it does

A screenshot flies up into the lower middle of the frame as a card. It has a soft shadow and a slight 3D tilt, and it settles flat. A light shine runs across it. A small chip on its top edge says "Real numbers". Then a highlighter swipe marks one area of the screenshot, for example the main number. Then the card leaves.

The card stays under the face, so the speaker stays visible.

The layer is transparent. It goes over the footage as an alpha layer.

Use it only when the user asks for it.

## What to change

Put the screenshot in `src/` as `shot.png`. It can be any size. The sample `shot.png` is a made-up analytics card for "Your name": replace it.

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `data-width`, `data-height` | The size of the edit in px, on `#root`. 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) and 1920x1080 (16:9) all work. The layout follows the shape (see below) |
| `SHOT.fit` | Per shape (`tall` = 9:16, `"4:5"`, `square` = 1:1, `wide` = 16:9): `maxW`, `maxH`, the largest size of the card (px; the screenshot fits inside, with its own shape), and `bottom`, the space under it. Make `bottom` larger to move the card up |
| `SHOT.side` | 16:9 only: `"left"` or `"right"`, the side of the frame for the card. Pick the side away from the face |
| `SHOT.radius` | The corner radius of the card |
| `HL.rect` | The area to highlight, in `shot.png` pixels: `{x, y, w, h}`. Set it to `null` for no highlight |
| `HL.color`, `HL.blend` | The highlighter colour and how it mixes with the screenshot |
| `CHIP.text` | The chip text. Set it to `""` for no chip |
| `TILT` | The start tilt in degrees: `rx` leans back, `ry` turns sideways, `rz` rotates |
| `AT` | When the card enters, when it settles, the chip, the highlight and its length, the exit (seconds) |
| `data-duration` | The length of the effect, on `#root` (seconds) |

To find `HL.rect`, open `shot.png` in an image viewer and read the pixel corners of the area. Make the rect a little larger than the text.

`HL.blend: "multiply"` looks like a real highlighter on a light screenshot. On a dark screenshot, use `"screen"` and a softer colour, for example `"rgba(255, 222, 60, 0.35)"`.

Keep the card under the chin. With a tall screenshot, make `maxH` smaller. A card top above about 55% of the frame height covers the mouth in a normal talking-head frame.

**Each shape.** 9:16, 4:5 and 1:1: the card is centred near the bottom, and it gets shorter as the frame gets shorter (`maxH` 760, 460, 380 px). 16:9: the card sits on one side (`SHOT.side`), up to 700x700 px. Outside 9:16 the chip text is 32 px.

Use only screenshots the user has the right to show. Blur or crop private names, emails and faces in the screenshot before you use it.

## How to make it for a video

1. Pick the cut time `T` where the card starts and its length `D` (6 s is typical).
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/proof-card/`.
3. Put the screenshot in that folder as `shot.png`. Change `HL`, `CHIP` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Add one step to the recipe. It renders the card with alpha (ProRes 4444):

   ```json
   "steps": [
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "proof-card", "--format", "mov", "-o", "proof-card.mov"],
      "makes": ["proof-card.mov"]}
   ]
   ```

5. Add the layer: `"over": [{"file": "_edit/<name>/proof-card.mov", "at": T, "alpha": true}]`.
6. Run `render_edit`, then `check_edit`. Look at a frame after the highlight. The highlight must sit on the right area, and the face must stay clear.

The layer does not need the footage, so it can cross cut points.

## Limits

- Made for 9:16, 4:5, 1:1 and 16:9. Other sizes use the layout of the nearest shape.
- In 1:1 the card is short, so small text in the screenshot gets smaller. Crop the screenshot to the part that matters.
- One screenshot and one highlight. For two highlights, copy the `#hl` element and its lines in the script.
- A very tall screenshot (a long thread) becomes small. Crop it to the part that matters first.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion. A screenshot card over a talking head is a common technique.
- Sample `shot.png`: made for Takes as HTML. The name and numbers are invented.
- Font: Inter, SIL Open Font License 1.1 (`src/fonts/OFL-Inter.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
