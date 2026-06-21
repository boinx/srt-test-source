# SRT Test Source

A small, self-hosted **SRT test source for macOS** — built to exercise SRT ingest in
[mimoLive](https://mimolive.com), but useful for testing any SRT receiver.

It streams a looping video file (or a synthetic test pattern) over SRT and **fans the
same stream out to multiple simultaneous receivers** — something a bare
`ffmpeg`/`srt-live-transmit` listener can't do (those are 1:1). It supports both SRT
**Listener** mode (receivers dial in) and **Caller** mode (the source dials out to a
receiver), and ships with a small **web dashboard** to watch connections and start/stop
caller pushes.

```
ffmpeg (file loop / pattern) ──SRT/MPEG-TS publish──▶ MediaMTX ──SRT listener──▶ N receivers (callers)
```

## Requirements

- macOS on **Apple Silicon**
- [Homebrew](https://brew.sh)
- `mediamtx`, and `ffmpeg` **built with libsrt** — `setup.sh` installs/verifies both
- `python3` (Command Line Tools) for the dashboard

## Quick start

```bash
git clone https://github.com/boinx/srt-test-source.git
cd srt-test-source
./setup.sh            # installs mediamtx + ffmpeg(libsrt), checks python3
./run.sh              # starts the streamer + dashboard
```

That's it — with no video configured it serves a **test card** plus the synthetic
**pattern** stream, so it works on a fresh clone with zero assets. To stream your own
clip, point `SRC_VIDEO` at it in `config.env` and re-run.

In your receiver (e.g. mimoLive), add an SRT source in **Caller** mode:

```
srt://<this-mac-ip>:8890?streamid=read:teststream     # the file / test card
srt://<this-mac-ip>:8890?streamid=read:pattern        # synthetic moving pattern
```

`run.sh` prints the URL with this Mac's LAN IP filled in. Open the same URL from as
many receivers as you like. If your receiver only accepts the standard streamid syntax,
use `streamid=#!::m=request,r=teststream`.

## Configuration (`config.env`)

| Variable | Default | Meaning |
|---|---|---|
| `SRC_VIDEO` | `~/Movies/srt-test.mp4` | Source clip for `teststream`. Missing → a test card is generated. |
| `SRT_PORT` | `8890` | SRT listener port (receivers connect here). |
| `API_PORT` | `9997` | MediaMTX control API (loopback only). |
| `DASH_PORT` | `8080` | Web dashboard (loopback only). |
| `PATTERN_BITRATE` | `3M` | Bitrate of the synthetic `pattern` stream. |

## Caller mode (source dials out to a receiver)

Set your receiver to SRT **Listener** on a port, then push to it. Two ways:

**One-shot:**
```bash
./caller.sh <receiver-ip> 9000          # push teststream to that listener (Ctrl-C to stop)
```

**Managed (dashboard + CLI)** — multiple endpoints, auto-reconnect:
```bash
./callers.sh add <receiver-ip> 9000               # push teststream
./callers.sh add <receiver-ip> 9000 pattern 200   # push pattern, latency 200ms
./callers.sh list
./callers.sh rm 1
./callers.sh clear
```

Each push pulls a running stream from MediaMTX and forwards it (stream-copy) to the
remote listener, and **auto-reconnects** if the receiver isn't up yet or restarts.

## Dashboard

Open **http://127.0.0.1:8080** (started by `run.sh`, or run `./dashboard.sh` alone).
It polls every 2s and shows:

- **Incoming SRT connections** — every reader/publisher with remote IP, path, and bytes.
- **Outgoing caller pushes** — start one from the form, watch its state, stop it.

MediaMTX has no built-in dashboard; this is a tiny stdlib-Python server (`control.py`)
on top of its control API.

### Always-on (optional)

By default the dashboard runs only while its terminal is open. To start the streamer +
dashboard at login and keep them alive:

```bash
./setup.sh --service      # or: ./service.sh install
./service.sh uninstall    # to remove
```

## How it works / notes

- **Multi-receiver fan-out** needs a media server. MediaMTX is the SRT listener; the
  ffmpeg generators *publish into it* over SRT/MPEG-TS, and it duplicates the stream to
  every reader. A lone ffmpeg listener only accepts one caller.
- **IPv4 binding.** MediaMTX is pinned to `0.0.0.0` on purpose: a bare `:port` binds
  IPv6-only on macOS, and IPv4 receivers then can't reach it (the SRT handshake fails
  silently). If a connection fails with nothing in the log, check `lsof -nP -iUDP:8890`
  shows `IPv4`.
- **MP4 → MPEG-TS.** The source is remuxed to a `.ts` (in `~/.cache/srt-test-source/`)
  and stream-copied: an `.mp4`/`.mov` paces badly under `ffmpeg -re` (drifts to ~0.66×
  real time), while a `.ts` copy holds 1.0× and preserves the original video *and* audio.
- **Firewall.** If macOS's firewall is on, allow `mediamtx` (and `ffmpeg` for caller
  mode) to accept/make connections, or other machines can't reach the streams.

## Files

| File | Purpose |
|---|---|
| `setup.sh` | Install/verify dependencies (`--service` also installs the launchd service). |
| `run.sh` | Start streamer + dashboard together. |
| `start.sh` | Build the `.ts`, render the config, run MediaMTX (streamer only). |
| `dashboard.sh` | Run the control server + web dashboard. |
| `caller.sh` | One-shot caller-mode push. |
| `callers.sh` | CLI for managed caller pushes (`add`/`list`/`rm`/`clear`). |
| `control.py` | Dashboard + caller-push manager (stdlib Python). |
| `config.env` | User settings. |
| `mediamtx.yml.tmpl` | MediaMTX config template (rendered by `start.sh`). |
| `service.sh` | Install/remove the always-on launchd service. |

## License

MIT — see [LICENSE](LICENSE).
