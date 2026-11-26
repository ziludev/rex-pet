# Make your own pet

The cat that ships with Rex Pet is drawn in code. Any state can be replaced by a clip instead,
which is what you want if you generate art rather than draw it.

```
green-screen clip  →  tools/make-pet.sh  →  hevc-with-alpha .mov  →  Assets/
```

## 1. Generate a clip

Shoot or generate a 16:9 video on a **pure green** background, one clip per state. What matters:

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
keying `0x00FF00`. Override with `SIZE=… FPS=… KEY=0xRRGGBB`.

The script keys the green, scales, and pipes raw frames into `tools/hevc-alpha-encoder.swift`, which
muxes an HEVC clip carrying an alpha channel — the format macOS `AVPlayerLayer` plays with real
transparency.

## 3. Install

```
cp build/assets/working.mov ~/Library/Application\ Support/rex-pet/Assets/
```

The app picks it up on the next state change. Resolution order per state:
`Assets/<state>.mov` → `Assets/<state>/*.png` (12 fps frames) → the built-in vector cat.

## Checking the result

```
ffprobe build/assets/working.mov          # one hevc stream, right size
```

If the cat turns into a black box on screen, the clip lost its alpha — re-encode rather than
editing the app.

## Credit

The encoder and the prompt recipes come from [dsh-pet](https://github.com/PC2005-cloud/dsh-pet)
(MIT), which in turn credits sunkeycn for the HEVC-with-alpha trick.
