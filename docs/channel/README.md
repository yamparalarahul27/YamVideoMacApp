# Channel style and video notes

This folder keeps the channel's editing style in Git, so a new Mac or a lost folder does
not lose it.

- `Style.md`: the channel's editing rules. Every agent reads it before it edits. The app
  keeps the live copy in `~/Library/Application Support/YamVideo/Library/Style.md`.
- `videos/`: each project's Video.md. YamVideo writes it next to the project at every save
  and export: the edit, the Shorts, the reasons for each choice and the history.
- `series/`: a recipe for each series, with the exact settings to use again.
- `assets/`: pictures made for the thumbnails.
- `macs/`: the list of video folders on each Mac, written by YamVideo. The Library uses
  them to say which Mac has a video. See [docs/footage-layout.md](../footage-layout.md).

## After each video

1. Save the project in YamVideo.
2. Run `docs/channel/sync.sh`. It copies Style.md and every Video.md here.
3. Commit and push, with `macs/`.

## On a new Mac

1. Build and open YamVideo once, then quit it.
2. Copy `docs/channel/Style.md` to `~/Library/Application Support/YamVideo/Library/Style.md`.
3. Open YamVideo. The Style sheet (⌘3) shows the rules.
4. In the Library, click the laptop button under the list and give this Mac its name.

Git does not keep the footage, the project files, the exports or the logo library
(`~/Library/Application Support/YamVideo/Logos`). Back them up on their own.
The footage folder layout is in [docs/footage-layout.md](../footage-layout.md).
