#!/usr/bin/env bash
#
# MediaConversionPipeline.sh — Media Magic: macOS media conversion orchestration
#
# Coordinates (in order): MakeMKV (Blu-ray only) → HandBrakeCLI → FileBot → Subler
#
# Official CLI documentation (verify flags against your installed versions):
#   MakeMKV:     https://www.makemkv.com/developers/usage.txt
#   HandBrake:   https://handbrake.fr/docs/en/latest/cli/cli-options.html
#   HandBrake presets (preset names): https://handbrake.fr/docs/en/latest/technical/official-presets.html
#   FileBot:     https://www.filebot.net/cli.html
#   Subler app:  https://github.com/SublerApp/Subler  (AppleScript suite: Subler.sdef)
#
# Standard install locations (Apple Silicon + Intel Homebrew); adjust if yours differ:
#   makemkvcon:  /Applications/MakeMKV.app/Contents/MacOS/makemkvcon
#                /opt/homebrew/bin/makemkvcon  OR  /usr/local/bin/makemkvcon
#   HandBrakeCLI: /Applications/HandBrake.app/Contents/MacOS/HandBrakeCLI
#                 /opt/homebrew/bin/HandBrakeCLI  OR  /usr/local/bin/HandBrakeCLI
#   filebot:     /Applications/FileBot.app/Contents/Resources/filebot.sh
#                /opt/homebrew/bin/filebot  OR  /usr/local/bin/filebot
#   Subler.app:  /Applications/Subler.app
#   SublerCLI:   /opt/homebrew/bin/SublerCLI  OR  /usr/local/bin/SublerCLI  (optional; see Subler stage)
#
# Version / behavior notes:
#   • HandBrake 1.6.0+ renamed 2160p presets to include "4K" in the name; the Devices preset
#     "Apple 2160p60 4K HEVC Surround" is listed in current official preset tables.
#     If CLI reports an unknown preset, retry with --preset-import-gui (GUI must have been
#     opened at least once so presets exist in ~/Library/Application Support/HandBrake/).
#   • HandBrakeCLI accepts --preset "Name" per CLI guide; older builds sometimes document -Z.
#   • MakeMKV: "makemkvcon mkv disc:0 all <folder>" matches usage.txt; disc index 0 is the
#     first drive — use makemkvcon -r info disc:9999 to list drives when multiple are present.
#   • FileBot CLI is strict by default; -non-strict enables opportunistic matching (filebot.net/cli.html).
#   • Subler's "fetch metadata" AppleScript handler applies metadata asynchronously; this script
#     waits SUBLER_METADATA_WAIT seconds before save (see Subler.sdef / ScriptCommand.swift).
#   • Subler automation requires a recent Subler build that includes the "Subler Automation Suite"
#     (fetch metadata, save, etc.). SublerCLI (bitbucket galad87) is optional for -optimize only.
#
set -u
IFS=$'\n\t'

readonly HANDBRAKE_PRESET='Apple 2160p60 4K HEVC Surround'

# Minimum wait after triggering Subler metadata fetch before save (async API in Subler.app).
: "${SUBLER_METADATA_WAIT:=90}"

PIPELINE_START_EPOCH=0
LOG_FILE=""
STAGE1_LOG=""
MAKEMKVCON=""
HANDBRAKECLI=""
FILEBOT=""
SUBLER_APP=""
SUBLERCLI=""

# Successful final titles (basename) for completion summary
declare -a SUCCESS_TITLES=()

log_line() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '[%s] %s\n' "$ts" "$*" >>"$LOG_FILE"
  elif [[ -n "${STAGE1_LOG:-}" ]]; then
    printf '[%s] %s\n' "$ts" "$*" >>"$STAGE1_LOG"
  fi
  printf '[%s] %s\n' "$ts" "$*" >&2
}

notify_user() {
  local title="$1"
  local msg="$2"
  osascript -e "display notification $(printf '%q' "$msg") with title $(printf '%q' "$title")" 2>/dev/null || true
}

dialog_error() {
  osascript -e "display alert \"Media Magic\" message $(printf '%q' "$1") as critical" 2>/dev/null || printf 'ERROR: %s\n' "$1" >&2
}

dialog_info() {
  osascript -e "display alert \"Media Magic\" message $(printf '%q' "$1") as informational" 2>/dev/null || printf '%s\n' "$1" >&2
}

# Resolve first existing path from a list (positional args).
resolve_first() {
  local p
  for p in "$@"; do
    if [[ -e "$p" && ! -d "$p" ]]; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

# --- Structural · Facade (decision tree: structure → simplify complex subsystem) ---
# Single entry aggregates path lookup for MakemKV / HandBrake / FileBot / Subler binaries.
init_tool_paths() {
  MAKEMKVCON=$(resolve_first \
    "/Applications/MakeMKV.app/Contents/MacOS/makemkvcon" \
    "/opt/homebrew/bin/makemkvcon" \
    "/usr/local/bin/makemkvcon" \
    "/usr/bin/makemkvcon" || command -v makemkvcon 2>/dev/null || true)
  HANDBRAKECLI=$(resolve_first \
    "/Applications/HandBrake.app/Contents/MacOS/HandBrakeCLI" \
    "/opt/homebrew/bin/HandBrakeCLI" \
    "/usr/local/bin/HandBrakeCLI" \
    "/usr/bin/HandBrakeCLI" || command -v HandBrakeCLI 2>/dev/null || true)
  FILEBOT=$(resolve_first \
    "/Applications/FileBot.app/Contents/Resources/filebot.sh" \
    "/Applications/FileBot.app/Contents/MacOS/filebot" \
    "/opt/homebrew/bin/filebot" \
    "/usr/local/bin/filebot" \
    "/usr/bin/filebot" || command -v filebot 2>/dev/null || true)
  if [[ -d "/Applications/Subler.app" ]]; then
    SUBLER_APP="/Applications/Subler.app"
  fi
  SUBLERCLI=$(resolve_first \
    "/opt/homebrew/bin/SublerCLI" \
    "/usr/local/bin/SublerCLI" \
    "/opt/homebrew/bin/SublerCli" \
    "/usr/local/bin/SublerCli" || command -v SublerCLI 2>/dev/null || command -v SublerCli 2>/dev/null || true)
}

validate_for_pipeline() {
  local missing=()
  [[ -n "$HANDBRAKECLI" ]] || missing+=("HandBrakeCLI")
  [[ -n "$FILEBOT" ]] || missing+=("FileBot")
  if [[ -z "$SUBLER_APP" && -z "$SUBLERCLI" ]]; then
    missing+=("Subler (Subler.app or SublerCLI)")
  fi
  if ((${#missing[@]} > 0)); then
    dialog_error "Missing required tools (not found at standard paths). Install or symlink them, then retry.

Missing: ${missing[*]}

See script header comments for typical paths and documentation URLs."
    exit 1
  fi
}

validate_makemkv() {
  if [[ -z "$MAKEMKVCON" ]]; then
    dialog_error "Blu-ray ripping requires MakeMKV (makemkvcon). Not found at standard paths.

See: https://www.makemkv.com/developers/usage.txt"
    exit 1
  fi
}

choose_output_directory() {
  osascript <<'APPLESCRIPT'
set theFolder to choose folder with prompt "Select the output folder for converted videos, FileBot/Subler processing, and log files:"
POSIX path of theFolder
APPLESCRIPT
}

choose_mkv_rip_directory() {
  osascript <<'APPLESCRIPT'
set theFolder to choose folder with prompt "Select the folder where MakeMKV should save ripped MKV files:"
POSIX path of theFolder
APPLESCRIPT
}

choose_video_files() {
  osascript <<'APPLESCRIPT'
set theFiles to choose file with prompt "Select one or more video files to convert:" with multiple selections allowed
set outList to {}
repeat with f in theFiles
	set end of outList to POSIX path of f
end repeat
set AppleScript's text item delimiters to return
set s to outList as string
set AppleScript's text item delimiters to ""
return s
APPLESCRIPT
}

# Step 1: source type + acquisition
prompt_source_flow() {
  local src_choice
  src_choice=$(osascript <<'APPLESCRIPT'
set r to display dialog "What is your source?" buttons {"Cancel", "Video File", "Disc"} default button "Video File"
set b to button returned of r
if b is "Video File" then return "file"
if b is "Disc" then return "disc"
error number -128
APPLESCRIPT
) || return 1

  if [[ "$src_choice" == "file" ]]; then
    local list
    list=$(choose_video_files) || return 1
    printf '%s' "$list"
    return 0
  fi

  local disc_type
  disc_type=$(osascript <<'APPLESCRIPT'
set r to display dialog "What type of disc — DVD or Blu-ray?" buttons {"Cancel", "DVD", "Blu-ray"} default button "DVD"
button returned of r
APPLESCRIPT
) || return 1

  if [[ "$disc_type" == "DVD" ]]; then
    local dvdroot
    dvdroot=$(osascript <<'APPLESCRIPT'
set theFolder to choose folder with prompt "Select the DVD root (the mounted volume or folder that contains VIDEO_TS):"
POSIX path of theFolder
APPLESCRIPT
) || return 1
    printf 'DVD\t%s' "$dvdroot"
    return 0
  fi

  if [[ "$disc_type" == "Blu-ray" ]]; then
    validate_makemkv || return 1
    local ripdir outlist
    ripdir=$(choose_mkv_rip_directory) || return 1
    ripdir=${ripdir%/}
    notify_user "MakeMKV" "Ripping Blu-ray to MKV — this may take a long time."
    # https://www.makemkv.com/developers/usage.txt — mkv disc:<idx> all <folder>
    # Disc index: first drive is 0; with multiple drives use: makemkvcon -r --cache=1 info disc:9999
    local disc_idx="${MAKEMKV_DISC_INDEX:-0}"
    log_line "MakeMKV: makemkvcon ... mkv disc:${disc_idx} all \"$ripdir\""
    if ! "$MAKEMKVCON" --messages=-same --progress=-same --cache=1024 mkv "disc:${disc_idx}" all "$ripdir" >>"$STAGE1_LOG" 2>&1; then
      dialog_error "MakeMKV failed while ripping Blu-ray. See temporary log: $STAGE1_LOG"
      return 1
    fi
    local mkvs
    mkvs=$(find "$ripdir" -maxdepth 1 -type f \( -iname '*.mkv' \) | LC_ALL=C sort)
    if [[ -z "$mkvs" ]]; then
      dialog_error "MakeMKV reported success but no MKV files were found in: $ripdir"
      return 1
    fi
    printf 'FILES\n%s' "$mkvs"
    return 0
  fi
  return 1
}

sanitize_basename() {
  local n=$1
  n=${n//[^A-Za-z0-9._ -]/_}
  printf '%s' "$n"
}

# --- Behavioural · Chain of responsibility (decision tree: behaviour → algorithms tried in sequence) ---
# Try default preset invocation first; delegate to preset-import fallback on failure.
_try_handbrake_encode() {
  local src="$1"
  local dest="$2"
  if "$HANDBRAKECLI" -i "$src" -o "$dest" --preset "$HANDBRAKE_PRESET" >>"$LOG_FILE" 2>&1; then
    return 0
  fi
  log_line "HandBrakeCLI: retry with --preset-import-gui."
  "$HANDBRAKECLI" --preset-import-gui -i "$src" -o "$dest" --preset "$HANDBRAKE_PRESET" >>"$LOG_FILE" 2>&1
}

run_handbrake_one() {
  local src="$1"
  local outdir="$2"
  local idx="$3"
  local total="$4"
  local base dest
  base=$(basename "$src")
  base=${base%.*}
  base=$(sanitize_basename "$base")
  dest="${outdir}/${base}.m4v"
  if [[ -e "$dest" ]]; then
    dest="${outdir}/${base}_${RANDOM}.m4v"
  fi
  notify_user "HandBrake" "Converting file ${idx} of ${total}…"
  log_line "HandBrakeCLI: source=$src output=$dest preset=$HANDBRAKE_PRESET"

  # HandBrake CLI: https://handbrake.fr/docs/en/latest/cli/cli-options.html (--preset).
  if _try_handbrake_encode "$src" "$dest"; then
    printf '%s\n' "$dest"
    return 0
  fi
  return 1
}

# https://www.filebot.net/cli.html — default CLI matching is strict; -non-strict matches GUI-style opportunistic mode.
# For TV episodes use: --db TheMovieDB::TV (same CLI reference).
run_filebot_rename_one() {
  local f="$1"
  local dir marker newest line
  dir=$(dirname "$f")
  marker=$(mktemp "${TMPDIR:-/tmp}/media_pipeline_fb.XXXXXX")
  touch "$marker" || {
    log_line "FileBot: could not create marker; assuming path unchanged."
    printf '%s' "$f"
    return 0
  }
  log_line "FileBot: filebot -rename \"$f\" --db TheMovieDB -non-strict"
  if ! "$FILEBOT" -rename "$f" --db TheMovieDB -non-strict >>"$LOG_FILE" 2>&1; then
    rm -f "$marker"
    return 1
  fi
  newest=$(find "$dir" -maxdepth 1 -type f \( -iname '*.m4v' -o -iname '*.mp4' -o -iname '*.mkv' \) -newer "$marker" 2>/dev/null | head -1)
  if [[ -z "$newest" ]]; then
    if [[ -e "$f" ]]; then
      newest="$f"
    else
      newest=$(find "$dir" -maxdepth 1 -type f \( -iname '*.m4v' -o -iname '*.mp4' \) -newer "$marker" 2>/dev/null | head -1)
    fi
  fi
  rm -f "$marker"
  [[ -n "$newest" ]] || newest="$f"
  printf '%s' "$newest"
  return 0
}

subler_optimize_cli() {
  local f="$1"
  [[ -n "$SUBLERCLI" ]] || return 0
  local tmp
  tmp="${f%.*}.subler_opt.m4v"
  log_line "SublerCLI: -source \"$f\" -dest \"$tmp\" -optimize (metadata atoms unchanged)"
  # PySubler / community docs: -source -dest -metadata ... -optimize
  if "$SUBLERCLI" -source "$f" -dest "$tmp" -metadata "{Media Kind:Movie}" -optimize >>"$LOG_FILE" 2>&1; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp"
    log_line "SublerCLI optimize failed (non-fatal)."
  fi
}

# Uses Subler.app AppleScript: open → fetch metadata → wait → save in place.
# Subler.sdef: command "fetch metadata" (automation suite).
# Implementation note: metadata search is asynchronous in Subler; we wait SUBLER_METADATA_WAIT seconds.
subler_app_metadata() {
  local f="$1"
  [[ -n "$SUBLER_APP" ]] || return 0
  local wait_sec="$SUBLER_METADATA_WAIT"
  log_line "Subler.app: AppleScript fetch metadata + save in place (wait ${wait_sec}s). See https://github.com/SublerApp/Subler (Subler.sdef)."
  osascript -l AppleScript - "$f" "$wait_sec" <<'OSA'
on run argv
  set mediaPath to item 1 of argv
  set waitSec to (item 2 of argv) as integer
  tell application "Subler"
    activate
    open POSIX file mediaPath
    delay 3
    try
      fetch metadata
    end try
  end tell
  delay waitSec
  tell application "Subler"
    try
      if (count of documents) > 0 then
        save document 1
        close document 1 saving no
      end if
    on err msg number n
      try
        close document 1 saving no
      end try
    end try
  end tell
end run
OSA
}

run_subler_stage() {
  local f="$1"
  local st=0
  if [[ -n "$SUBLER_APP" ]]; then
    subler_app_metadata "$f" || st=$?
  fi
  subler_optimize_cli "$f" || true
  return "$st"
}

# --- Behavioural · Strategy (implicit): each prompt_source_flow branch emits a typed token;
# decoding is consolidated here instead of branching in main().
populate_sources_from_flow() {
  local flow=$1
  SOURCES=()
  case "$flow" in
  DVD$'\t'*)
    SOURCES+=("${flow#*$'\t'}")
    ;;
  FILES$'\n'*)
    local body=${flow#*$'\n'}
    while IFS= read -r line; do
      [[ -n "$line" ]] && SOURCES+=("$line")
    done <<<"$body"
    ;;
  *)
    while IFS= read -r line; do
      [[ -n "$line" ]] && SOURCES+=("$line")
    done <<<"$flow"
    ;;
  esac
}

main() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'This script must run on macOS.\n' >&2
    exit 1
  fi

  init_tool_paths
  STAGE1_LOG=$(mktemp /tmp/media_pipeline_stage1.XXXXXX.log)
  export STAGE1_LOG
  # shellcheck disable=SC2064
  trap 'rm -f "${STAGE1_LOG:-}"' EXIT

  local flow
  flow=$(prompt_source_flow) || {
    printf 'Cancelled.\n' >&2
    exit 0
  }

  local outdir
  outdir=$(choose_output_directory) || exit 0
  outdir=${outdir%/}
  mkdir -p "$outdir"
  LOG_FILE="${outdir}/conversion_log_$(date '+%Y-%m-%d').txt"
  touch "$LOG_FILE"
  if [[ -f "$STAGE1_LOG" && -s "$STAGE1_LOG" ]]; then
    printf '\n--- Early-stage log (e.g. MakeMKV before output folder was chosen) ---\n' >>"$LOG_FILE"
    cat "$STAGE1_LOG" >>"$LOG_FILE"
    printf '\n--- Main pipeline log ---\n' >>"$LOG_FILE"
  fi
  rm -f "$STAGE1_LOG"
  STAGE1_LOG=""
  trap - EXIT

  PIPELINE_START_EPOCH=$(date +%s)
  log_line "=== Media Magic session start ==="

  declare -a SOURCES=()
  populate_sources_from_flow "$flow"

  if ((${#SOURCES[@]} == 0)); then
    dialog_error "No source files were selected or produced."
    exit 1
  fi

  validate_for_pipeline

  local total=${#SOURCES[@]}
  local i=0
  local src encoded renamed
  for src in "${SOURCES[@]}"; do
    ((++i))
    if [[ ! -e "$src" ]]; then
      dialog_error "Source missing (stage: validate): $src"
      log_line "Missing source: $src"
      continue
    fi
    encoded=""
    if ! encoded=$(run_handbrake_one "$src" "$outdir" "$i" "$total"); then
      dialog_error "HandBrake failed on file ${i} of ${total}.

Source: $src
Log: $LOG_FILE"
      log_line "HandBrake FAILED: $src"
      continue
    fi
    renamed=""
    notify_user "FileBot" "Renaming file ${i} of ${total}…"
    if ! renamed=$(run_filebot_rename_one "$encoded"); then
      dialog_error "FileBot failed (stage: rename) on:

$encoded
Log: $LOG_FILE"
      log_line "FileBot FAILED: $encoded"
      continue
    fi
    notify_user "Subler" "Embedding metadata (${i} of ${total})…"
    if ! run_subler_stage "$renamed"; then
      dialog_error "Subler stage reported an error (AppleScript/CLI) for:

$renamed
Log: $LOG_FILE"
      log_line "Subler FAILED: $renamed"
      continue
    fi
    SUCCESS_TITLES+=("$(basename "$renamed")")
    log_line "SUCCESS pipeline for: $renamed"
  done

  local end elapsed min sec list msg
  end=$(date +%s)
  elapsed=$((end - PIPELINE_START_EPOCH))
  min=$((elapsed / 60))
  sec=$((elapsed % 60))
  list=""
  for t in "${SUCCESS_TITLES[@]}"; do
    list+=$'\n'" • $t"
  done
  msg="Converted ${#SUCCESS_TITLES[@]} of ${total} file(s).${list}

Total elapsed time: ${elapsed} seconds (${min} min ${sec} sec)

Log file:
$LOG_FILE"
  dialog_info "$msg"
  log_line "=== Media Magic session end (${#SUCCESS_TITLES[@]} ok) ==="
}

main "$@"
