# YamVideo MCP server

Connects Claude Code, Codex or any MCP client to the project open in YamVideo on this
Mac, so an agent can edit alongside you. It is a thin stdio adapter: every tool runs
[`yamvideoctl`](../YamVideoCLI/README.md), which finds the running app, checks that its
socket is private to you and speaks the protocol. YamVideo validates every edit, and each
one becomes an ordinary undo step credited to the agent.

Nothing here edits files, opens network ports or uploads footage. One exception, by
design: `yamvideo_render_preview` attaches the frame it renders to the tool result so the
agent can see it, and that result goes wherever your client sends tool results — usually
its model provider. Pass `attachImage: false` to keep frames on the Mac (the result still
has the file path).

## Set up

1. Build YamVideo (`./build.sh`), which also builds `build/yamvideoctl`, and open it.
2. Install the adapter's two pinned dependencies (Node 18 or later):

   ```sh
   cd Tools/AgentBridge && npm ci
   ```

3. Register it with your client. Use absolute paths; replace `/path/to/YamVideoMacApp`
   with where this repository is. `YAMVIDEO_CLIENT` is the name YamVideo shows in Undo
   and the activity list. The Local agents panel in YamVideo can copy these commands with
   the paths filled in.

**Claude Code** (checked against Claude Code 2.1.241's `claude mcp add --help`):

```sh
claude mcp add yamvideo -s user \
  -e YAMVIDEO_CLIENT=Claude \
  -e YAMVIDEO_CTL=/path/to/YamVideoMacApp/build/yamvideoctl \
  -- node /path/to/YamVideoMacApp/Tools/AgentBridge/server.mjs
```

`-s user` makes it available in every project; leave it out to add it to the current
directory only. `claude mcp list` shows it.

**Codex** (from OpenAI's Codex MCP documentation, October 2026; not yet run against an
installed Codex on the development Mac):

```sh
codex mcp add yamvideo \
  --env YAMVIDEO_CLIENT=Codex \
  --env YAMVIDEO_CTL=/path/to/YamVideoMacApp/build/yamvideoctl \
  -- node /path/to/YamVideoMacApp/Tools/AgentBridge/server.mjs
```

or in `~/.codex/config.toml`:

```toml
[mcp_servers.yamvideo]
command = "node"
args = ["/path/to/YamVideoMacApp/Tools/AgentBridge/server.mjs"]
# Exports and `yamvideo_get_job` with wait can outlast the 60 s default.
tool_timeout_sec = 600

[mcp_servers.yamvideo.env]
YAMVIDEO_CLIENT = "Codex"
YAMVIDEO_CTL = "/path/to/YamVideoMacApp/build/yamvideoctl"
```

YamVideo never writes either client's configuration for you.

## Check it

With a recording open in YamVideo:

```sh
cd Tools/AgentBridge && npm run smoke
```

It drives the server through the official MCP client — read, dry run, apply, a refused
stale edit, a preview, undo — and prints a JSON summary. Its edit is undone before it
exits. `./test.sh` runs the same check against a test instance.

## Tools

| tool | does |
|---|---|
| `yamvideo_list_sessions` | Running instances and their open project. |
| `yamvideo_get_state` | The project as committed, with stable IDs and timing. |
| `yamvideo_apply_edits` | 1–100 typed commands as one undo step, against a revision; `dryRun` to check first. |
| `yamvideo_get_events` | What changed since a cursor, and who changed it. |
| `yamvideo_render_preview` | A frame as a PNG (path, and the image unless `attachImage` is false). |
| `yamvideo_analyze` | Silence or zoom suggestions as a job; applies nothing. |
| `yamvideo_get_job`, `yamvideo_cancel_job` | Job status and result (optionally waiting), or cancel. |
| `yamvideo_save_project` | Save in place, first save, or a copy — no dialog. |
| `yamvideo_export` | Export one recording or the movie as a job. |
| `yamvideo_undo`, `yamvideo_redo` | The named step only, never someone else's. |
| `yamvideo_reveal` | Move your view to something the agent wants to show you. |

The server's instructions teach the agent the workflow: read state, plan, apply with the
revision it read, and on `revision_conflict` read again rather than guess. Command types
and fields are listed in `yamvideo_apply_edits`'s description and in the
[yamvideoctl guide](../YamVideoCLI/README.md).

## When something is refused

| error | meaning |
|---|---|
| `app_not_running` | Open YamVideo (and build it if `yamvideoctl` is missing). |
| `agents_paused` | You switched off "Allow agent edits" in YamVideo's Local agents panel. |
| `revision_conflict` | Someone edited since the agent read state; it should read again. |
| `interaction_in_progress` | You are mid-drag; the agent retries when you let go. |
| `export_in_progress` | An export is running; edits resume when it ends. |
| `wrong_session` | The project was reopened or replaced; read state again. |

## Dependencies

`@modelcontextprotocol/sdk` 1.31.0 and `zod` 4.6.5, pinned exactly, with
`package-lock.json` committed. Both were at least two weeks old when chosen.
