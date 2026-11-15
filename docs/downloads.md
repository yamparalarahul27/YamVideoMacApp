# Local Downloads

Open **Downloads** in the sidebar or press **⌘5**. Paste a video link, optionally
inspect its title/thumbnail/duration, choose Video or Audio and quality, then
Download. Video downloads can be imported into Studio. Finished files can be
revealed in Finder or copied again. Removing history does not delete files.

Downloads use the local `yt-dlp`, `ffmpeg`, `ffprobe` and `deno` tools. Install with
`brew install yt-dlp ffmpeg deno`; keep yt-dlp current with `brew upgrade yt-dlp`.
The app checks standard Homebrew/MacPorts paths. It does not bundle these tools,
a remote API, or Pixel Point's application code. Site support depends on yt-dlp.
Video output preserves the chosen source quality, preferring compatible codecs
at the selected resolution; separate streams merge to MP4 or MKV. Audio-only
output is M4A. Private/login-dependent links can use a browser session explicitly
selected in the form; no cookies are read by default or stored in app history.

Each job downloads to its own staging folder before completed files are moved
into the selected destination. Existing filenames are never overwritten. Queue
and history live under `~/Library/Application Support/YamVideo/Downloads/`.
Interrupted jobs are marked cancelled on reopening and can be retried. Cancellation
and failure clean up the job's partial directory. Retry starts the download again.

The Swift `DownloadEngine` constructs process arguments directly, parses structured
JSON progress, and uses `Shell.run` to drain both streams while the process runs.
No shell evaluates the supplied URL. HTTP and HTTPS URLs without embedded user
credentials are accepted. The local queue runs one download at a time.

Run `Tools/test-downloads.sh` for URL/argument/progress checks and a real local HTTP
media test covering inspection, queued and active cancellation, retry, duplicate
filenames, audio extraction and persistent history. The test creates its own
short video and HTTP server; it does not download third-party media.
