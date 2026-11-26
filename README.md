# Nocturne

Nocturne is an offline music player built with Cipher. It decodes FLAC files, reads synchronized lyrics, plays through the local audio service, and renders mixes to WAV without a network connection or a separately installed Cipher runtime.

## Requirements

- Zig 0.17.1 and a Cipher checkout at `../Cipher`, or pass `-Dcipher-root=/path/to/Cipher`.
- A Unix-like system with a supported audio output service for interactive playback.
- No separately installed Cipher runtime or default font is required. The default font and its OFL license are compiled into the executable.

## Build and verify

```sh
zig build -Dcipher-root=/path/to/Cipher
zig build test-audio -Dcipher-root=/path/to/Cipher
zig build dist -Dcipher-root=/path/to/Cipher -Doptimize=ReleaseSafe
```

`test-audio` verifies generated FLAC fixtures against the `flac` and `ffmpeg` tools. `probe` scans a collection directory and reports decoder errors and MD5 mismatches:

```sh
zig build probe -Dcipher-root=/path/to/Cipher -- /path/to/music
```

The collection probe is diagnostic evidence, not a claim that every possible FLAC encoder or file is supported. Files with unsupported codecs are reported rather than silently skipped. The `/home/sifr/Music` collection is a local verification corpus and is not redistributed by this repository.

## Runtime boundary

The executable contains the application and framework code. It links only the platform C runtime on the tested Linux x86_64 host; it does not require a separate Cipher runtime. Interactive use requires the system audio service and a display/compositor. Offline rendering does not require either service.

## Current scope

- Offline FLAC playback and WAV rendering.
- Library scanning, playlists, synchronized lyrics, and sample-exact crossfade.
- Native Cipher UI and independent application build/test/release lifecycle.

There is no streaming service integration, network client, or guarantee that every FLAC extension or metadata layout is supported. A failing file is surfaced with a diagnostic error rather than treated as successful playback.
