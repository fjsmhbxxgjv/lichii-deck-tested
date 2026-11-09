# Deck testing — The Legend of Zelda: Ocarina of Time (Switch 2)

How the fixes in this fork are tested on a Steam Deck, what was measured,
and how to reproduce it. No personal information is included here: all
paths use `$HOME`, all network identifiers are omitted, and results are
reported as measured numbers only.

## Hardware under test

- Steam Deck (LCD), 16 GB RAM, AMD Van Gogh APU (Zen 2, 4 cores / 8 threads),
  RDNA 2 GPU, Mesa 26.1.99 / RADV.
- BIOS UMA frame buffer set to 4 GB (the only performance-relevant BIOS
  setting on the stock Deck BIOS).
- Game: The Legend of Zelda: Ocarina of Time (Switch 2 remake), Title ID
  `0400486024DEC000`.
- Display: external TV over USB-C dock, Desktop Mode, X11
  (`QT_QPA_PLATFORM=xcb`). Wayland is avoided: Lichii shows a blocking
  "Wayland Detected! Use X11 instead" dialog there.

## Base build

All fixes here are on top of the mja00 Lichii-OOT v2.2 snapshot
(`lichii-oot-v2.2`). The stock v2.2 build is the baseline; the test
builds below are measured against it.

## Test method

The test is fully scripted (`tools/deck-test-run.sh`) so it runs the same
way every time, with no manual input. It:

1. Backs up and deletes the game's save data (only that title's save,
   never the whole NAND), so the title menu has no Continue option and a
   single confirm press starts a new game.
2. Launches the build fullscreen at 1x resolution (`resolution_setup=3`)
   with a 20-minute limit.
3. Takes a screenshot every 5 seconds from launch.
4. Waits up to 2 minutes for the title screen, checking the process is
   alive; if the game dies at startup, it relaunches (up to 10 attempts).
5. Focuses the window and presses confirm (held ~0.5 s — a brief tap does
   not register), retrying up to 5 times; the intro starting is confirmed
   by video-decode activity in the game log. If a save exists, confirm
   may need two presses (select Continue, then load the save slot) — the
   retry loop covers this.
6. After the intro / save load settles (~30 s), drives into gameplay:
   holds forward (W) 3 s to reach the door, holds confirm (C) 2 s to
   open it, holds back+confirm (S+C) 10 s, then holds confirm (C) 2 s.
7. Samples CPU / GPU-busy / temperature every 20 seconds while the game
   runs.
8. If the game dies mid-run, the whole cycle restarts (up to 3 cycles).

Measurements come from the emulator log, not from watching the screen:

- Intro video smoothness: `TickFrame` frames-per-second windows and the
  `DecodeLoop` line count (decoded video frames).
- 3D gameplay: `TickFrame` fps in the first gameplay area, against a
  30 fps target at 1x.
- Load: CPU %, GPU busy %, APU temperature, sampled every 20 s.
  (Note: the CPU % in the log is sampled from the launcher process and
  can read low; GPU busy % is the reliable load metric. The earlier
  manual play session measured CPU properly at ~279% avg, ~309% peak.)

Input notes (verified by experiment):

- The confirm key needs a ~0.5 s hold to register; a brief tap does not
  move the menu.
- Confirm only works with the keyboard player mapping (confirm = C) and
  no virtual gamepad active; with a gamepad mapping the keyboard bindings
  are absent.
- A fully black frame can be a video fade or a shader-build pause, not a
  crash — confirm a crash by checking the process, not the screenshot.
- Do not stop or restart the game mid-test: the emulator shows an "Are
  you sure you want to quit?" dialog on a close request, which looks like
  a crash in the log. If an instance dies, report it and let the operator
  decide; do not relaunch autonomously outside the script's retry logic.

## Fixes and their test status

Only fixes that were measured on the Deck are marked tested. A ported
fix with no Deck-tested binary yet is marked untested — it is in the
source, but its effect is unverified.

### Tested — video decode fix (intro video 8 fps → ~60 fps at 1x)

Commit: `Video decode fix: restore hardware pix_fmt and prefer VAAPI`.

Root cause: the base build dropped the negotiated hardware pixel format
in `DecoderContext::InitializeHardwareDecoder`
(`src/video_core/host1x/ffmpeg.cpp`) — the format was marked
`[[maybe_unused]]` and never stored — so the GPU video path never
engaged and decoding fell back to libdav1d capped at 4 threads.

Changes:

- `ffmpeg.cpp`: restore `m_codec_context->pix_fmt = hw_pix_fmt;` in
  `InitializeHardwareDecoder`, remove `[[maybe_unused]]`.
- `ffmpeg.cpp`: prefer VAAPI over VDPAU/CUDA on Unix
  (`PreferredGpuDecoders` order VAAPI, VDPAU, CUDA; Vulkan stays last).
- `nx2_video_decoder.cpp`: CPU-fallback `thread_count = 4` → `0`
  (auto). This one is flagged for A/B testing: an upstream issue
  (#929) shows uncapped dav1d can collide with pinned GPU threads and
  collapse a cutscene to single-digit fps on a many-core host, so
  `0` vs a fixed `2–4` is still to be compared on the Deck.

Caveat: the Deck's RADV driver does not expose
`VK_KHR_video_decode_av1` or a video-decode queue, so the Vulkan AV1
path cannot engage on this hardware. The Deck does have VAAPI
(libva + `radeonsi_drv_video.so`, VCN 3.0), which is the likelier
working GPU route; VAAPI engagement is still to be confirmed in the
log (`Using vaapi GPU decoder`).

Measured (Deck, 1x resolution):

| | Baseline (v2.2) | With fix |
|---|---|---|
| Intro video | ~8 fps (frame 600, ~10 s of video, reached after ~73 real s) | ~60 fps (TickFrame 56.8 and 61.8 fps windows; debug fps 61.6) |
| Title screen | ~60 fps | ~60 fps |
| Decode activity | 1 DecodeLoop line in a full play session | 12,587 DecodeLoop lines / 1,212 decoded frames in one run |

3D gameplay fps at 1x is now measured on the native build (see below):
~8–12 fps in Kokiri Forest at 1x (frame times 80–124 ms), GPU 99–100%
busy. Still well short of the 30 fps target.

### Tested — native build v2 (movie-network bypass + mesh fallback active)

Binary: `lichii-test-v2`, built natively on the Deck host (glibc 2.43 /
Qt 6.11) so it runs directly on the host with no container. The
container test binary was abandoned after 25+ consecutive startup
SIGABRT deaths across three retest cycles; the native build removes
that variable. Build note: the test suite (`src/tests`) fails to compile
under `-Werror=shadow` (`sysmix_test_context.h` shadows members of
`SysmixTests::Stream`), so tests are disabled for this build — the
emulator itself compiles clean.

Measured (Deck, 1x resolution, native build):

| | Intro video | 3D gameplay (Kokiri Forest) |
|---|---|---|
| v2 (native) | ~59 fps (frame time ~16.9 ms; DecodeLoop active) | ~8–12 fps (frame times 80–124 ms) |
| Baseline (v2.2) | ~8 fps | ~9 fps at 0.25x (1x unmeasured) |

Log evidence that the ported fixes are live in this build:

- Movie-network bypass: `DispatchNativeCompute: Native network pass
  0x216c6b0500 replaced by input copy` appears repeatedly — the
  Eglantine port is active.
- Mesh fallback: `Mesh fallback: VK_EXT_mesh_shader disabled` — the
  #814 port is active.

Both fixes are therefore now TESTED (present and running in a
Deck-tested binary), but the gameplay number shows they do not by
themselves reach 30 fps at 1x. The bottleneck is elsewhere; the next
builds target the split-GPU-thread port (#805), the uniform-bank
upload skip (#909), the fence-delayed semaphore fix (#911), and
FSR3 frame generation / async presentation (config).

### Ported, untested — movie-network bypass + drop late movie frames

Commit: `Port Eglantine movie fixes for Ocarina of Time`.

Ports Eglantine `92f119195f` (replace Ocarina's movie network by an
input copy) and `1f52ac7e2e` (drop late movie frames). Rationale: the
intro may be display/enhancement-bound, not decode-bound — the game
runs a DLSS-style movie-enhancement network that needs tensor cores,
and `MaxDecodedAhead = 2` means decode outputs only as fast as the
game displays. The port replaces only the movie network's upscaling
store pass with a plain copy and leaves the gameplay network alone.

Status: in source, no Deck-tested binary built with it yet. Do not
present it as a measured improvement.

### Ported, untested — mesh compute fallback as the RADV default

Commit: `Mesh compute fallback as the RADV default (zortos293 #814)`.

Ports upstream zortos293 #814 (from #569/#316): native task/mesh draws
reset the GPU within minutes on AMD, so mesh fallback becomes the
default on RADV. Upstream `EDEN_NX2_FORCE_MESH_FALLBACK` disables
`VK_EXT_mesh_shader` so task/mesh draws fall back to the classic path;
it was absent from the mja00 base and is ported here.

Status: in source, no Deck-tested binary built with it yet. Do not
present it as a measured improvement.

### Build-only fixes (no behaviour change claimed)

- `Fix -Werror=shadow in vk_pipeline_cache.cpp` — build fix.
- `Fix Nx2VideoInputQueue API name in DropOvertakenFrames` — build fix.

## Baseline measurements (stock v2.2, for comparison)

- Intro tapestry: 9 fps, 123 ms frames.
- Intro video: ~8 fps CPU decode (see table above).
- Play session (manual, ~3 min): CPU avg ~279%, peak ~309% (3+ cores);
  GPU busy 23% (intro) → 98–100% (3D); APU temp 64–78 °C, no
  throttling; system RAM 90–94% used (tight).
- Perf settings used for all runs: Vulkan backend, FXAA, `oot_30fps`,
  handheld mode, async shaders on, `force_max_clock`, CPU accuracy
  Unsafe, async GPU emulation, disk shader cache. Resolution 1x for
  all fix measurements (0.25x was used only for early exploration).

## Known instability (test binary)

The container test binary was flaky at startup, which is why the script
retries:

- Startup SIGABRT, ~60 s after launch, log ending ~1.7 s in
  (Vulkan/texture init), same signature as a cubeb/ALSA init abort.
  Transient — a relaunch usually clears it. Seen 5 times in one
  evening, then 25+ consecutive times in a later retest (three cycles,
  all attempts) — at that point the container binary was abandoned in
  favour of the host-native build, which does not show the pattern.
- Silent deaths mid-intro and on the title screen, no error, no
  coredump. Also seen in the stock build (silent death at the first
  door after ~28 min of play; SIGBUS coredumps exist for both builds).

The stock AppImage does not show the startup SIGABRT pattern when
launched manually on the host; the container test binary only ran
inside the build container (it needs glibc/Qt versions the Deck host
does not ship), and that container launch is where the flakiness
lived. The host-native build (`lichii-test-v2`) removes that variable.

Memory: the build and a test must not run at the same time on the
Deck. Running both starved RAM (game ~7 GB + build) and the kernel's
oomd terminated the test scope ("Memory Shortage Avoided"). Pause the
build whenever a test is running.

## Reproducing a run

1. Build the test binary from this source (see `docs/Build.md`).
2. Copy `tools/deck-test-run.sh` to the Deck, make it executable.
3. Run it detached so it survives the SSH session:
   `systemd-run --user --scope --unit=zelda-test ~/deck-test-run.sh`
   (`setsid`/`nohup` alone do not survive an SSH disconnect here.)
4. Follow `/tmp/test-run.log` and `/tmp/test-shots/` on the Deck.
5. Report: cutscene decode fps, 3D fps at 1x, CPU/GPU/temp, and
   exactly where it stalls or crashes. Do not claim a number that was
   not measured in the log.
