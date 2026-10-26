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
│  └─ References/                         videos the owner likes, to study (never reused)
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
| A YamDraw export (`recording.mp4`, `frame-NN.png`, `session.json`), kept together | `Recorded/YamDraw <topic>/` |
| Project (`.yamvideo`) and its `Video.md` | top of the video folder |
| Long video export: `.mp4`, `.en.srt`, thumbnail, `YouTube.txt`, `.youtube.json` | `Edited/` |
| Short export: `.mp4`, `.en.srt`, cover, `YouTube.txt`, `.youtube.json` | `Edited/Shorts/` |
| Thumbnail made in YamVideo, saved frame, graphics images, other work files | `Files/` |
| `Blur notes.md`: personal information in the recordings, with times | `Files/` |
| `Recordings.md`: one line for each recording: day, length, what it shows, which video it is for | `Files/` |
| `Plan.md`: the edit plan an agent writes before the first edit (Agents Manual 4.16) | `Files/` |
| Transcripts of the recordings (`.txt` timed sentences, `.srt`, `.words.json`) | `Files/Transcripts/` |
| Image for more than one video | `Shared Assets/` |
| A video the owner likes, kept to study its style: the video, `Contact sheet.png`, `Frames/` and its notes. Git keeps a copy of the notes in `docs/channel/references/` | `Shared Assets/References/<name>/` |
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
      `Screen Recording YYYY-MM-DD at …`. For a DJI clip, trust the file name: in
      October 2026 the camera's time zone was UTC+5:00, so its `creation_time` was
      30 min off.
   2. Find the topic. Look at 3 or 4 frames from the file.
   3. Find the video folder. Use a folder with the same topic and day, or make a new
      `YYYY-MM-DD Title` folder with `Recorded/`, `Edited/` and `Files/`.
   4. Move the file into `Recorded/`. Do not change its name.
   5. Move `.LRF` files to the Trash.
   6. Look for personal information in each screen recording and screenshot: names, PAN,
      Aadhaar, signatures, email addresses, phone numbers, bank details, home area. Sample
      a frame every few seconds, not every 20 s. Write each item with its time range in
      `Files/Blur notes.md`: **Must** for ID numbers, signatures and contact details, Ask
      for the rest.
   7. Add one line for each file to `Files/Recordings.md`: day, length, what it shows,
      and which video or Short it is for.
   8. Tell the owner where each file went. If the topic is not clear, ask the owner.
3. The agent studies the new recordings, writes `Files/Plan.md` for each video, asks the
   owner the questions that block each plan, and plans the release days for at least two
   months (Agents Manual 4.16 and 4.17). The owner approves each plan before the edit.

## Rules

- Do not rename or move a recording after a project uses it. A project keeps the full
  path of each recording and each graphics image. If a move is necessary, use Locate
  Source in YamVideo (the agent command `relinkMedia`) for each recording.
- Before an export, read `Files/Blur notes.md` and hide each Must item with a Blur area
  and the item's time range (Start Here and End Here in the blur area's inspector, or
  `addBlurArea` with `start` and `end`). The times are in the recording, so cuts do not
  move them. Cut the part when the video does not need it.
- Do not delete a file with `rm`. Move it to the Trash, so the owner can put it back.
- Keep only the newest export of a video in `Edited/`. Move the older export files to
  the Trash after the new export passes its checks.
- To add past videos to the Library, use Scan a Folder on `Yamparala Media`. The scan
  looks in all the folders.

## More than one Mac

The footage is not in Git, so each Mac has different videos. YamVideo keeps a list of the
video folders on each Mac in Git, so every Mac can see where a video is.

- Each Mac has a short name, like `Equicom` or `Yamparala`. Set it in the Library: click
  the laptop button under the list.
- YamVideo writes this Mac's list to `docs/channel/macs/<name>.json` when it opens, when
  the Library opens and after each project save. The list has each video folder, its
  project ids, its recording names, its number of exports and its size. It has no
  footage. YamVideo writes the file only when a folder changed.
- YamVideo reads the lists of the other Macs. In the Library, an idea whose project is
  only on another Mac says "On Yamparala", and **Only on other Macs** lists the video
  folders that are not on this Mac.
- Commit and push `docs/channel/macs` after each video, with each `Video.md`. Pull on
  the other Mac to see the change.
- Only the app built in the YamVideo source folder (`build/YamVideo.app`) writes a list.
  The footage folder is `~/Desktop/Yamparala Media`; the `footageFolder` setting
  (`defaults write com.equicomtech.yamvideo footageFolder PATH`) changes it.

## On a new Mac

1. Make `~/Desktop/Yamparala Media` with `Inbox/`, `Shared Assets/` and `Other/`.
2. Copy the video folders into it. Keep the same user name and path: projects keep full
   paths. If the path is different, open the project and use Locate Source.
3. Build YamVideo, open it, and give the Mac its name in the Library (the laptop button).
4. Run `docs/channel/sync.sh` after each video, then commit and push `docs/channel`.
