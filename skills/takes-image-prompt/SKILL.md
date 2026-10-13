---
name: takes-image-prompt
description: Write strong prompts for GPT Image 2.5 (Flare, Sunburst) and make the image in Takes with make_image. Use when the user asks for an image, a thumbnail, a cover, a poster, an infographic, a product shot, a UI mockup, a character sheet or a portrait, asks to change an image, or asks for a better image prompt. Finds proven example prompts from the YouArt collection of 150 GPT Image 2.5 prompts.
---

# Takes image prompt

Write the prompt like a short brief, look at what came out, then change one thing at a time.
The image tool is `make_image` in the `takes` MCP (GPT Image 2.5 Flare for a new image, Sunburst
for a change, Nano Banana 2.1 as the cheap fallback). The image lands in
`<session>/generated/<name>-vN.png` and shows on the Assets tab.

## 1. Find two or three examples first

`scripts/find_prompts.py` searches the YouArt collection
(github.com/youart-open-source/awesome-gpt-image-2-5-prompts: 150 prompts by 110 authors, 9 use
cases). It downloads the collection once a day.

```bash
python3 scripts/find_prompts.py --categories            # poster, typography-text, infographic, ui-mockup,
                                                        # ecommerce-product, ad-creative, character-design,
                                                        # portrait, illustration
python3 scripts/find_prompts.py youtube thumbnail -n 3  # best matches for these words
python3 scripts/find_prompts.py --category infographic -n 2
```

Read the examples for their structure, not their subject. Take the shape (which sections, in
which order, how exact) and write a new prompt for the user's image. The prompts belong to their
authors: do not paste one into a post or a public file; when an example shaped the prompt a lot,
name the author and the link in your reply.

## 2. Write the prompt

Order the brief the way a viewer reads the picture:

1. **What the finished thing is**, with its shape: "A 16:9 YouTube thumbnail…", "A 4:5 LinkedIn
   cover…", "A square product photo…". Pass the same shape as `format`.
2. **Layout** before style: where the subject sits (left third, centre, close-up from the chest
   up), how many panels, what goes at the top and the bottom. Say counts: "exactly 1 person",
   "exactly 3 text blocks".
3. **Subject details**: who or what, clothes, expression, materials. Be concrete.
4. **Text in the image**: put every word in quotes, say where it sits and what the type looks
   like ("heavy rounded sans, white with a dark outline"), not a font name. Keep it short:
   three to six words per block. Number the blocks when there are more than one.
5. **Camera and light** for photos: lens ("50 mm", "macro"), angle, depth of field, where the
   light comes from, the grade.
6. **Colour**: three or four colours by name ("deep navy, warm orange, off-white").
7. **Avoid** as a short last line: "Avoid: extra text, watermarks, logos, extra fingers,
   stock-photo look."

Long briefs work best as `Label: value` lines (Goal, Canvas, Layout, Subject, Text, Camera,
Colour, Avoid). Use JSON only when the image has many separate parts (an infographic with a
header, callouts and a footer).

Fill every placeholder from an example (`{argument name="…" default="…"}`, `[BRAND]`). A
placeholder left in the prompt is drawn as text.

## 3. Changes and references

- **Change an image**: `images=[the file]`, then the one change first, then what must stay:
  "Make the background dark navy. Keep the face, the pose, the text and the framing the same."
- **References** (up to 16): say what each one gives. "Image 1 is the face to keep. Image 2 is
  the colour palette. Image 3 is the layout."
- **A face that must stay the user's own**: use one of their stills from `stills/` or a frame of
  the keeper take as image 1, and list what to keep (face shape, eyes, hair, skin tone).
- **A character that comes back**: make one character sheet first (front, side, back, three
  expressions), then pass that sheet as the reference for every later image.

## 4. Make it and look at it

```
make_image(session=…, prompt=…, format="16:9", quality="medium", name="thumb-hook")
```

- `quality="low"` for quick tries, `medium` by default, `high` only for the final.
- Open the file with the Read tool and check it before you reply: text spelled right and not
  cut off, the right number of people and hands, the subject where the brief put it, the
  important parts outside the platform's covered areas (a thumbnail's bottom-right corner shows
  the video length).
- Wrong? Change one thing in the prompt and make it again. Do not rewrite the whole brief.
- Show the result with `open_in_app` only when the user asked to see it there.

## Example

"A 16:9 YouTube thumbnail. Layout: the man from image 1 on the right third, chest up, looking
at the camera, surprised. Left two thirds: exactly 2 text blocks, stacked: 1) \"I CUT MY
VIDEO\" in heavy white rounded sans with a thick black outline, 2) \"IN 60 SECONDS\" in the
same type, bright yellow. Background: his desk at night, out of focus, warm orange lamp light
from the left, deep blue shadows. Colour: deep navy, warm orange, yellow, white. Keep his face,
hair and glasses exactly as in image 1. Avoid: extra text, logos, watermarks, extra hands."
