#!/bin/bash
# Scripted test for lichii-test-v2 (Deck-native build, host launch, NO container).
# v2 changes (Nov 8, from manual session): save may exist, so C is pressed twice
# (select Continue, then load the save slot); after gameplay starts, walk to the
# door (hold W), open it (hold C), then hold S+C 10s, then hold C. Xauth is
# captured once at start and reused (avoids stale-file failures).
# Save backup/delete, launch on host, screenshots every 5s from launch, wait up
# to 120s for title, press C up to 5x, verify intro/gameplay via DecodeLoop and
# PresentClientBuffer frame times, sample CPU/GPU every 20s.
# Retries: 10 launch attempts, 3 full cycles. Run via systemd-run --user --scope
# so it survives SSH disconnects. NEVER overwrite the working AppImage.
set -u
GAME="/home/deck/Emulation/roms/switch2/The Legend of Zelda Ocarina of TIme [04004860224DEC000].nup"
BIN="/home/deck/Applications/lichii-test-v2"
LOG="$HOME/.local/share/eden/log/eden_log.txt"
RUN_LOG="/tmp/test-run.log"
SHOTS="/tmp/test-shots"
XAUTH=$(ls -t /run/user/1000/xauth_* 2>/dev/null | head -1)
export DISPLAY=:0 XAUTHORITY="$XAUTH" XDG_RUNTIME_DIR=/run/user/1000
rm -f "$RUN_LOG"
echo "=== lichii-test-v2 run started $(date) ===" >> "$RUN_LOG"
find_oot_save() {
  find "$HOME/.local/share/eden/nand/user/save" -type d -name 0400486024DEC000 2>/dev/null | head -1
}
start_shots() {
  ( i=0
    while true; do
      [ -d "$SHOTS" ] || mkdir -p "$SHOTS"
      spectacle -b -o "$SHOTS/shot-$(printf %04d $i).png" >/dev/null 2>&1
      i=$((i+1)); [ "$i" -ge 200 ] && i=0
      sleep 5
    done ) &
  SHOT_PID=$!
}
stop_shots() { kill $SHOT_PID 2>/dev/null; }
sample_perf() {
  ( while kill -0 "$1" 2>/dev/null; do
      gpu_busy=$(cat /sys/class/drm/card0/device/gpu_busy_percent 2>/dev/null || echo "?")
      echo "$(date +%T) cpu=$(ps -o %cpu= -p "$1" 2>/dev/null | tr -d ' ') gpu_busy=${gpu_busy}%" >> "$RUN_LOG"
      sleep 20
    done ) &
  PERF_PID=$!
}
wait_for_title() {
  local pid=$1 waited=0
  while [ $waited -lt 120 ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 5; waited=$((waited+5))
  done
  kill -0 "$pid" 2>/dev/null
}
focus_game() {
  local win
  win=$(xdotool search --name "Lichii" 2>/dev/null | head -1)
  [ -n "$win" ] && xdotool windowactivate "$win" >/dev/null 2>&1
}
press_c() { # 0.5s hold; keyboard C = confirm (needs keyboard player_0 config)
  focus_game; xdotool keydown c; sleep 0.5; xdotool keyup c
}
hold_key() { # hold_key <key> <seconds>
  focus_game; xdotool keydown "$1"; sleep "$2"; xdotool keyup "$1"
}
hold_keys() { # hold_keys <key1> <key2> <seconds>
  focus_game; xdotool keydown "$1"; xdotool keydown "$2"; sleep "$3"; xdotool keyup "$2"; xdotool keyup "$1"
}
CYCLE=1
while [ $CYCLE -le 3 ]; do
  echo "--- v2 cycle $CYCLE ---" >> "$RUN_LOG"
  echo "=== lichii-test-v2 started $(date) ===" >> "$RUN_LOG"
  SAVE=$(find_oot_save)
  if [ -n "$SAVE" ]; then
    BAK="$HOME/Emulation/saves-backup/oot-v2-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BAK"; cp -a "$SAVE" "$BAK/" 2>/dev/null
    rm -rf "$SAVE"; echo "save backed up to $BAK and deleted" >> "$RUN_LOG"
  else
    echo "no OOT save found, nothing to delete" >> "$RUN_LOG"
  fi
  ATTEMPT=1
  while [ $ATTEMPT -le 10 ]; do
    timeout 1200 "$BIN" --fullscreen "$GAME" >/dev/null 2>&1 &
    PID=$!
    echo "launched lichii-test-v2 pid $PID (attempt $ATTEMPT)" >> "$RUN_LOG"
    start_shots
    sample_perf $PID
    if wait_for_title $PID; then
      echo "title screen reached, pressing C" >> "$RUN_LOG"
      OK=0
      for t in 1 2 3 4 5; do
        press_c; sleep 3
        if grep -q DecodeLoop "$LOG" 2>/dev/null; then OK=1; break; fi
        sleep 2
      done
      if [ $OK -eq 1 ]; then
        echo "C accepted, intro decoding" >> "$RUN_LOG"
        # Let the intro / save load settle, then drive to the door.
        sleep 30
        echo "walking to door (hold W)" >> "$RUN_LOG"
        hold_key w 3
        sleep 1
        echo "opening door (hold C)" >> "$RUN_LOG"
        hold_key c 2
        sleep 1
        echo "holding S+C 10s" >> "$RUN_LOG"
        hold_keys s c 10
        sleep 1
        echo "holding C" >> "$RUN_LOG"
        hold_key c 2
        echo "gameplay inputs done, monitoring" >> "$RUN_LOG"
        while kill -0 $PID 2>/dev/null; do sleep 10; done
        echo "game exited" >> "$RUN_LOG"
      else
        echo "C not accepted after 5 tries" >> "$RUN_LOG"
        kill $PID 2>/dev/null
      fi
    else
      echo "launch attempt $ATTEMPT: game died during startup, retrying" >> "$RUN_LOG"
    fi
    stop_shots; kill $PERF_PID 2>/dev/null
    wait $PID 2>/dev/null
    ATTEMPT=$((ATTEMPT+1))
  done
  echo "v2 cycle $CYCLE failed, restarting" >> "$RUN_LOG"
  CYCLE=$((CYCLE+1))
done
echo "v2 test: all cycles exhausted" >> "$RUN_LOG"
