# Footage folder layout

All footage, projects and exports for the channel are in one folder:
`~/Desktop/Yamparala Media`. Use the same folder and the same layout on each Mac. YamVideo
and its agents follow this layout, so a new recording goes to the correct place and each
export lands next to its video.

```
Yamparala Media/
├─ Inbox/                                drop new recordings here
├─ 2026-10-17 AgentUX System Design Part 1/
│  ├─ AgentUX-System-Design.yamvideo     the project
│  ├─ AgentUX-System-Design Video.md      written by YamVideo at each save and export
│  ├─ Recorded/                           camera and screen recordings, as recorded
│  │  └─ Joined/                          takes joined into one file (when needed)
│  ├─ Edited/                             Export for YouTube: video, captions, thumbnail, text
│  │  └─ Shorts/                          each Short with its captions, cover and text
│  └─ Files/                              thumbnails, graphics images, other work files
├─ 2026-10-19 Sahi/
│  └─ Recorded/ · Edited/ · Files/
├─ Shared Assets/                         images for more than one video (gear, logos, app screens)
└─ Other/                                 recordings that are not for a video
```

## Video folders

- Give each video one folder: `YYYY-MM-DD Title`. The date is the day of its first
  recording, so Finder sorts the folders by time. Write the title in words, for example
  `2026-10-14 AppStore Learnings`.
- Add `Part 1`, `Part 2` for a series.
- Give each video folder the three folders `Recorded`, `Edited` and `Files`, also when
  they are empty.
- Put the recordings of one topic from one session in one folder, also when they give
  more than one video. Example: `2026-10-19 Sahi` holds two headshots and two screen
  recordings.

## What goes where

| Item | Folder |
|---|---|
| Camera clip (DJI `.MP4`), Mac screen recording (`.mov`), iPhone or iPad screen recording (`RPReplay_*.MP4`) | `Recorded/` |
| Takes joined into one file for a project | `Recorded/Joined/` |
| Project (`.yamvideo`) and its `Video.md` | top of the video folder |
| Long video export: `.mp4`, `.en.srt`, thumbnail, `YouTube.txt`, `.youtube.json` | `Edited/` |
| Short export: `.mp4`, `.en.srt`, cover, `YouTube.txt`, `.youtube.json` | `Edited/Shorts/` |
| Thumbnail made in YamVideo, saved frame, graphics images, other work files | `Files/` |
| Image for more than one video | `Shared Assets/` |
| DJI `.LRF` file (a low-resolution preview from the camera) | the Trash; YamVideo does not use it |

YamVideo uses this layout when no output folder is set:

- Export and Export for YouTube suggest the video's `Edited/` folder.
- Export Short for YouTube suggests `Edited/Shorts/`.
- Thumbnails and saved frames go to `Files/`.
- The first save of a project suggests the video folder.

A recording that is not in a `Recorded/` folder keeps the old default: its files go next
to it. The code is `Sources/FootageLayout.swift`.

## New recordings

1. The owner drops each new file into `Inbox/`. A file at the top of
   `Yamparala Media` is also new.
2. An agent sorts each new file:
   1. Find the date. Use `ffprobe` (`format_tags=creation_time`) or the file name: DJI
      clips are `DJI_YYYYMMDDhhmmss_*`, Mac screen recordings are
      `Screen Recording YYYY-MM-DD at …`.
   2. Find the topic. Look at 3 or 4 frames from the file.
   3. Find the video folder. Use a folder with the same topic and day, or make a new
      `YYYY-MM-DD Title` folder with `Recorded/`, `Edited/` and `Files/`.
   4. Move the file into `Recorded/`. Do not change its name.
   5. Move `.LRF` files to the Trash.
   6. Tell the owner where each file went. If the topic is not clear, ask the owner.

## Rules

- Do not rename or move a recording after a project uses it. A project keeps the full
  path of each recording and each graphics image. If a move is necessary, use Locate
  Source in YamVideo (the agent command `relinkMedia`) for each recording.
- Do not delete a file with `rm`. Move it to the Trash, so the owner can put it back.
- Keep only the newest export of a video in `Edited/`. Move the older export files to
  the Trash after the new export passes its checks.
- To add past videos to the Library, use Scan a Folder on `Yamparala Media`. The scan
  looks in all the folders.

## On a new Mac

1. Make `~/Desktop/Yamparala Media` with `Inbox/`, `Shared Assets/` and `Other/`.
2. Copy the video folders into it. Keep the same user name and path: projects keep full
   paths. If the path is different, open the project and use Locate Source.
3. Run `docs/channel/sync.sh` after each video to keep each `Video.md` in Git.
