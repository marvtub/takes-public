# Step aside in pauses

## What it does

The screen recording fills the frame. You sit in a round bubble in a corner. When you stop talking for 1.5 s or more (you click, you wait for a page, you read), the bubble fades out and the screen has the whole frame. It fades back in just before your next word.

It is two parts: this folder's `src/make-bubble.sh` makes the bubble layer, and `render_edit` does the hiding (`"hide_in_silence": true` on the layer). Takes finds the pauses in the edit's word times. A cut of the screen file has no transcript of its own: Takes borrows the camera file's words and moves them by how much later the screen file started, found by lining up the sound of both files.

Use it only when the user asks for it, or when their rules say so. Everyone grows their own style.

## What to change

| Value | What it controls |
|---|---|
| `x`, `y`, `side` | The square of the camera (its pixels) that fills the bubble. Put the face in its middle, with some room around it: the bubble does not move when the face does |
| `size` | The bubble's width as a share of the frame's shorter side. About 0.3 in 16:9, 0.4 in 9:16 |
| `corner` | `br`, `bl`, `tr` or `tl`. Pick the corner where the screen shows nothing that matters |
| `hide_in_silence` | On the layer in `over`. Off: the bubble stays the whole time |

The pause length (1.5 s), the fades (0.3 s), how long the bubble stays after the last word (0.3 s) and how early it is back (0.15 s before the next word) are fixed in `render_edit` (`HIDE_GAP`, `HIDE_FADE`, `HIDE_AFTER`, `HIDE_BEFORE`).

## How to make it for a video

1. Get the take's files from `get_session`: `take-NN-camera.mov` and `take-NN-screen.mov`. The recipe's `cut` uses the screen file (`"kind": "screen"`).
2. The camera file starts at another moment than the screen file. `get_session` shows `screen_lag_s` on the screen take: the camera time of a moment is its screen time minus `screen_lag_s` (measured by lining up the sound of both files, to 10 ms). So for a screen part with `in` = `a`, the bubble's `<start>` is `a - screen_lag_s`.
3. Look at a frame of the camera and pick `x`, `y` and `side`.
4. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/hide-in-silence/`.
5. Add the step and the layer to the recipe. `<W>` x `<H>` is the edit's size, `<fps>` its frame rate, `<length>` the cut's length:

   ```json
   "steps": [
     {"run": ["sh", "hide-in-silence/make-bubble.sh", "../../<take>-camera.mov", "bubble.mov",
              "<W>", "<H>", "<fps>", "<start>", "<length>", "<x>", "<y>", "<side>", "0.3", "br"],
      "makes": ["bubble.mov"]}
   ],
   "over": [{"file": "_edit/<name>/bubble.mov", "at": 0, "alpha": true, "hide_in_silence": true}]
   ```

   For a cut of several parts, make one bubble per part (one step and one layer each, `at` = where the part starts in the cut).
6. Run `render_edit`, then `check_edit`. Look at a frame in a pause (no bubble), one just before the next word (the bubble back) and one while you talk (the face in the bubble).

`hide_in_silence` works on any picture layer, not only this bubble: a side-by-side layer or a label fades out in the pauses the same way.

## Limits

- The bubble is a still crop of the camera. If you move a lot, pick a bigger `side`. `frame.crop` with `follow_face` follows the face, but only for the camera that fills the frame.
- A pause is a gap between words. A cough or a laugh with no word in it counts as a pause.
- Without words (no transcript of either file), the bubble stays the whole time.
- The step needs ffmpeg. No network.
