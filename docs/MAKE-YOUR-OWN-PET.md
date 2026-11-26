# Make your own pet

Rex Pet plays a clip per state, and the five clips in `Assets/` are the reason the default pet looks
the way it does. Replace any of them — with generated art, a recording, or a clip borrowed from
[dsh-pet](https://github.com/PC2005-cloud/dsh-pet) — and the app uses yours instead. Delete them all
and the cat drawn in `Sources/CatSprite.swift` takes over.

```
clip (green screen or alpha)  →  tools/make-pet.sh  →  hevc-with-alpha .mov  →  Assets/<state>.mov
```

If you would rather ship a PNG sequence than a clip, `Themes/` has five examples and
`tools/install-theme.sh` encodes one into the same `.mov` format — copy that layout
(`Themes/<name>/<state>/001.png`) if you want to keep yours alongside it.

## 1. Get a clip

Two kinds of source work: a green-screen video you generated, or a clip that already carries alpha
(VP9-alpha webm included — the script tells them apart by extension and reads the alpha plane with
`-c:v libvpx-vp9`, since ffmpeg's native decoder drops it).

Either way, one clip per state. What matters:

- the character stays in the same place for the whole clip, so states cut without jumping —
  head around 20% from the top, feet around 85%;
- for looping states the **first and last frame must match**, otherwise the loop ticks;
- no shadows on the background, no green spill on the subject.

Prompt recipes for exactly this (idle loops, sleep, wake) are in
[dsh-pet/prompts](https://github.com/PC2005-cloud/dsh-pet) — that project does the same thing for a
browser pet, and its wording works unchanged here.

## 2. Convert

```
tools/make-pet.sh <state> <clip.mp4> [output-dir]
```

`state` is one of `idle`, `working`, `blocked`, `done`, `error`. Defaults: `320x300` at `24 fps`,
keying `0x00FF00`, quality `0.7`, `PAD=0.06`. Override with `SIZE=… FPS=… KEY=0xRRGGBB QUALITY=… PAD=…`.

The script finds the subject's bounding box from the alpha of a few sampled frames, crops to it (plus
`PAD`), keys the green if there is any, fits the result into `SIZE` without stretching, and pipes raw
frames into `tools/hevc-alpha-encoder.swift`, which muxes an HEVC clip carrying an alpha channel — the
format macOS `AVPlayerLayer` plays with real transparency.

That crop is the step that matters for borrowed art: a clip made for a browser window is 16:9 with the
character in the middle third, so without it the pet is a speck in a large empty frame.

## 3. Install

```
cp build/assets/working.mov ~/Library/Application\ Support/rex-pet/Assets/
```

The app picks it up on the next state change. Resolution order per state, per location — your folder
first, then the copy inside the app:

`Assets/<state>.mov` → `Assets/mov/<state>.mov` → `Assets/<state>/loop.mov` → `Assets/<state>/*.png`
(12 fps frames) → the drawn cat.

## Checking the result

```
ffprobe build/assets/working.mov          # one hevc stream, right size
```

If the cat turns into a black box on screen, the clip lost its alpha — re-encode rather than
editing the app.

## Credit

The encoder and the prompt recipes come from [dsh-pet](https://github.com/PC2005-cloud/dsh-pet)
(MIT), which in turn credits sunkeycn for the HEVC-with-alpha trick.
