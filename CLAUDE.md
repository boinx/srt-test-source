# SRT Test Source — agent guide

Self-hosted SRT test source for **macOS (Apple Silicon)**: a MediaMTX SRT listener that fans a
looping video file or a synthetic pattern out to multiple receivers, with caller-mode pushes and
a web dashboard. Built to test mimoLive's SRT ingest. Public repo (`boinx/srt-test-source`, MIT) —
no secrets in commits; `config.env` is gitignored. Full usage is in `README.md`.

## Run it
```bash
./setup.sh     # installs/verifies deps: mediamtx, ffmpeg WITH libsrt, python3; creates config.env
./run.sh       # streamer + dashboard together (Ctrl-C stops both)
# or separately: ./start.sh (streamer) and ./dashboard.sh (dashboard)
```
Needs Homebrew. Edit `config.env` (ports, `SRC_VIDEO`, `PATTERN_*`) — it's copied from
`config.env.example` by `setup.sh`.

## Verify it works
```bash
lsof -nP -iUDP:8890                                       # TYPE must read IPv4 (gotcha #1)
ffprobe "srt://127.0.0.1:8890?streamid=read:teststream"   # should show h264 + aac
curl -s http://127.0.0.1:9997/v3/paths/list               # MediaMTX API: teststream (and pattern) ready
# dashboard: http://127.0.0.1:8080   (ports are the defaults; see config.env)
```

## Architecture
- **MediaMTX** is the SRT listener (`:8890`) and fans one stream out to N readers. Its config is
  rendered from `mediamtx.yml.tmpl` by `start.sh` into `~/.cache/srt-test-source/mediamtx.gen.yml`.
- **teststream** = a pure stream-copy of a `.ts` sidecar `start.sh` builds from `SRC_VIDEO`
  (default `media/test.mp4`), published by MediaMTX `runOnInit` over SRT.
- **pattern** = a synthetic A/V generator owned by `control.py` (the dashboard), publishing into
  MediaMTX. Resolution / fps / bitrate are live-configurable; "A/V-sync blink" makes the 1 kHz tone
  and a white patch turn on/off together each second.
- **caller mode** = `caller.sh` (one-shot) or the dashboard / `callers.sh` (managed, auto-reconnect)
  push a stream to a remote SRT *listener*.
- **control.py** = dashboard + pattern generator + caller manager (stdlib Python, no deps).

## Don't undo these (hard-won; each silently breaks things)
1. **IPv4 binding.** `srtAddress: 0.0.0.0`, `apiAddress: 127.0.0.1` — never a bare `:port`. On macOS
   Go binds `:port` IPv6-only, so IPv4 clients (ffmpeg, mimoLive over the LAN) can't reach it and the
   SRT handshake fails **with no log on either side**. Verify `lsof -nP -iUDP:8890` shows `IPv4`.
2. **MP4 → MPEG-TS.** teststream streams a `.ts` stream-copy, NOT the `.mp4`. An `.mp4`/`.mov` paces
   badly under `ffmpeg -re` (drifts to ~0.66× real time). Keep the remux, and keep the **original
   audio** — do not substitute a tone (a prior "fix" the user reverted).
3. **Publish over SRT/MPEG-TS, not RTSP.** Stream-copying AAC from TS into an RTSP hop fails ("AAC
   with no global headers"); `-bsf:a aac_adtstoasc` does NOT fix it. TS→TS over SRT needs no header
   extraction.
4. **pattern needs the dashboard.** It's a defined-but-empty ingest path that `control.py` publishes
   into; MediaMTX **rejects** publishing to undefined paths. `start.sh` alone serves only teststream.
5. **Target Python 3.9** (macOS system python). Keep code 3.9-compatible — notably, no backslashes
   inside f-string expressions (use `%`-formatting).
6. **Hardware encoder.** `h264_videotoolbox` keeps 1080p60 real-time; `libx264` can't.

## Known finding
teststream (1080p60, VBR stream-copy, 2 s GOP) makes a real-time receiver drop many frames where the
720p30 pattern is smooth. It is NOT buffering (raising the receiver's SRT latency to 1000 ms didn't
help) → decode/render-bound at the receiver. Left as-is on purpose as a realistic stress case; use
the dashboard pattern generator (vary res/fps) to bisect what the receiver can sustain.
