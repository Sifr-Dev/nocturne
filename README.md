# Nocturne

An offline music player built on Phantom, with a from-zero FLAC decoder and synchronized lyrics.

<p>
  <a href="https://github.com/Sifr-Dev/nocturne/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/Sifr-Dev/nocturne/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="Zig 0.17.1" src="https://img.shields.io/badge/ZIG-0.17.1-ffb86b?logo=zig&logoColor=white">
  <img alt="Tests: 26 passing" src="https://img.shields.io/badge/TESTS-26_PASSING-39c5cf">
  <img alt="License: MIT" src="https://img.shields.io/badge/LICENSE-MIT-2ea043">
</p>

> Framework dependency: Phantom (repository `Sifr-Dev/Phantom`), pinned at
> `fca41d8`. The product name and repository slug are unchanged.

## What it is

Nocturne decodes FLAC files, reads synchronized lyrics, plays through the local
audio service, and renders mixes to WAV without a network connection. Its FLAC
decoder, resampler, playlist and lyrics handling are in this repository; it does
not use a system media framework, and it does not require a separately installed
Phantom runtime.

## Current capabilities

- **From-zero FLAC decoder** — `src/audio/flac.zig`; `zig build test-audio`
  (4 tests) compares decoded output with the `flac` and `ffmpeg` reference tools
  on generated fixtures.
- **Synchronized lyrics** — LRC sidecars and embedded VORBIS LYRICS comments,
  `src/audio/lrc.zig`; exercised by the audio suite and the player path in
  `src/audio/player.zig`.
- **M3U/M3U8 playlists and library scan** — `src/audio/playlist.zig`,
  `src/main.zig`; playlist parsing and the collection probe are covered by
  `zig build probe -- /path/to/music`.
- **Deterministic resampling and output-format conversion** — `src/resampler.zig`,
  `src/output_format.zig`; `zig build test-format` (17 tests) covers rate
  conversion, bit-depth handling, clipping bounds and repeatability.
- **Bounded interactive playback conversion** — mono and stereo sources are
  converted to signed 16-bit stereo at the source rate; multichannel sources are
  rejected explicitly. `tests/playback_test.zig` (5 tests) asserts the bounds.
- **PulseAudio output via dlopen()** — `src/audio/pulse.zig`; no link-time audio
  dependency. Playback opens the local Pulse/PipeWire-compatible service.
- **Sample-exact crossfade** — `src/audio/player.zig`, covered by the playback
  suite.
- **Native Phantom UI** — library list, now-playing view, progress, lyric pane
  and crossfade control in `src/main.zig`.
- **Offline WAV rendering** — `--render-wav OUT.wav` writes the mix without an
  audio server; used by the tests.

## Quick start

```sh
git clone https://github.com/Sifr-Dev/Phantom.git Cipher
git clone https://github.com/Sifr-Dev/nocturne.git nocturne
cd nocturne
zig build -Dcipher-root=../Cipher
zig build dist -Dcipher-root=../Cipher -Doptimize=ReleaseSafe

./zig-out/bin/nocturne /path/to/music
./zig-out/bin/nocturne /path/to/music --render-wav /tmp/mix.wav
```

Requirements: Zig 0.17.1, a Wayland compositor for interactive use, and
PulseAudio or PipeWire's PulseAudio-compatible service for sound. Offline WAV
rendering needs neither a compositor nor an audio server. `flac` and `ffmpeg`
are needed only for the differential test.

## Verification

Run on this host (Ryzen 7 7435HS, RTX 4060 Laptop, Linux, Zig 0.17.1, `flac`
and `ffmpeg` installed):

```sh
zig build -Dcipher-root=../../repositories/Cipher
zig build test-audio -Dcipher-root=../../repositories/Cipher --summary all
zig build test-playback -Dcipher-root=../../repositories/Cipher --summary all
zig build test-format -Dcipher-root=../../repositories/Cipher --summary all
zig build -Dcipher-root=../../repositories/Cipher -Doptimize=ReleaseSafe
```

Observed: all commands exit 0. Test totals: **26 tests passed** — audio 4,
playback 5, format/resampler 17. The audio suite requires the external `flac`
and `ffmpeg` binaries; it does not silently pass without them.

## Architecture

```
src/main.zig           app entry, library/now-playing/lyrics UI, CLI
src/audio/flac.zig     from-zero FLAC decoder
src/audio/lrc.zig      LRC and embedded VORBIS LYRICS parsing
src/audio/playlist.zig M3U/M3U8 parsing and collection scan
src/audio/player.zig   playback state, crossfade, WAV rendering
src/audio/pulse.zig    PulseAudio-simple output via dlopen
src/audio/wav.zig      WAV read/write used by tests and rendering
src/resampler.zig      deterministic rate conversion
src/output_format.zig  source-to-output format conversion and bounds
tests/                 differential audio, playback-bounds and resampler suites
```

## Limitations

- Interactive playback supports mono and stereo only; more than two channels is
  rejected with a diagnostic instead of being downmixed.
- Interactive output is converted to signed 16-bit PCM; bit-perfect hardware
  playback and gapless output are not claimed.
- The decoder covers the FLAC subset exercised by the fixtures and the local
  collection; exotic metadata layouts and unsupported codecs are reported as
  errors, not silently skipped.
- No network, streaming or online metadata integration by design.
- The verification corpus under `/home/sifr/Music` is local and not distributed
  with this repository.

## Roadmap (NOT IMPLEMENTED)

- Multichannel decode and explicit downmix policy.
- Gapless playback and bit-perfect device output.
- Broader FLAC/metadata conformance coverage.
- Packaged release artifacts.

## License

MIT — see `LICENSE`.
