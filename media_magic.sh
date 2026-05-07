#!/bin/bash

# Media Magic macOS automation pipeline
#
# Official CLI references used for command design:
# - MakeMKV CLI: https://www.makemkv.com/developers/usage.txt
# - HandBrakeCLI: https://handbrake.fr/docs/en/latest/cli/cli-options.html
# - FileBot CLI: https://www.filebot.net/cli.html
# - Subler project / CLI: https://github.com/SublerApp/Subler
#
# Typical macOS install locations:
# - MakeMKV: /Applications/MakeMKV.app/Contents/MacOS/makemkvcon
# - HandBrakeCLI: /opt/homebrew/bin/HandBrakeCLI or /usr/local/bin/HandBrakeCLI
# - FileBot: /Applications/FileBot.app/Contents/MacOS/filebot or Homebrew path
# - SublerCLI: /Applications/Subler.app/Contents/MacOS/SublerCLI
#
# Version notes:
# - HandBrake preset names can change across releases; this script verifies
#   "Apple 2160p60 4K HEVC Surround" exists via --preset-list before running.
# - MakeMKV disc selectors (e.g., disc:0) follow official usage docs; if your
#   optical drive maps differently, adjust MAKEMKV_DISC_SELECTOR below.
# - FileBot database and formatting flags can vary by release / license mode;
#   this script uses common -rename/--db/--format conventions from CLI docs.
# - SublerCLI metadata search flags differ by build; script tries two known
#   syntaxes and logs failures so users can adapt to local SublerCLI behavior.

set -uo pipefail

HANDBRAKE_PRESET="Apple 2160p60 4K HEVC Surround"
MAKEMKV_DISC_SELECTOR="disc:0"

SCRIPT_NAME="Media Magic"
START_EPOCH="$(date +%s)"
LOG_FILE=""
OUTPUT_DIR=""

MAKEMKV=""
HANDBRAKE=""
FILEBOT=""
SUBLER=""

SOURCE_KIND=""
DISC_TYPE=""
DISC_PATH=""
RIP_DIR=""

SOURCE_FILES=()
COMPLETED_TITLES=()

show_alert() {
  local message="$1"
  osascript -e "display alert \"${SCRIPT_NAME}\" message \"${message//\"/\\\"}\" as critical buttons {\"OK\"} default button \"OK\"" >/dev/null
}

show_dialog() {
  local message="$1"
  osascript -e "display dialog \"${message//\"/\\\"}\" with title \"${SCRIPT_NAME}\" buttons {\"OK\"} default button \"OK\"" >/dev/null
}

show_notification() {
  local message="$1"
  osascript -e "display notification \"${message//\"/\\\"}\" with title \"${SCRIPT_NAME}\"" >/dev/null
}

choose_from_list() {
  local prompt="$1"
  shift
  osascript - "$prompt" "$@" <<'APPLESCRIPT'
on run argv
  set thePrompt to item 1 of argv
  set optionList to items 2 thru -1 of argv
  set selectedOption to choose from list optionList with prompt thePrompt OK button name "Continue" cancel button name "Cancel"
  if selectedOption is false then error number -128
  return item 1 of selectedOption
end run
APPLESCRIPT
}

choose_folder() {
  local prompt="$1"
  osascript -e "POSIX path of (choose folder with prompt \"${prompt//\"/\\\"}\")"
}

choose_files() {
  local prompt="$1"
  osascript - "$prompt" <<'APPLESCRIPT'
on run argv
  set chosenFiles to choose file with prompt (item 1 of argv) with multiple selections allowed
  set outputLines to ""
  repeat with f in chosenFiles
    set outputLines to outputLines & (POSIX path of f) & linefeed
  end repeat
  return outputLines
end run
APPLESCRIPT
}

log_line() {
  local line="$1"
  if [[ -n "$LOG_FILE" ]]; then
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line" >> "$LOG_FILE"
  fi
}

run_and_log() {
  local stage="$1"
  shift
  log_line "[$stage] COMMAND: $*"
  "$@" >> "$LOG_FILE" 2>&1
  local status=$?
  log_line "[$stage] EXIT CODE: $status"
  return $status
}

resolve_tool_path() {
  local label="$1"
  shift
  local candidate
  for candidate in "$@"; do
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

list_media_files() {
  find "$OUTPUT_DIR" -maxdepth 1 -type f \( -name "*.m4v" -o -name "*.mp4" \) | LC_ALL=C sort
}

calc_elapsed() {
  local end_epoch elapsed hours mins secs
  end_epoch="$(date +%s)"
  elapsed=$((end_epoch - START_EPOCH))
  hours=$((elapsed / 3600))
  mins=$(((elapsed % 3600) / 60))
  secs=$((elapsed % 60))
  printf '%02d:%02d:%02d' "$hours" "$mins" "$secs"
}

# 0) Startup tool validation (all required tools must exist before pipeline runs)
MAKEMKV="$(resolve_tool_path "MakeMKV" \
  "/Applications/MakeMKV.app/Contents/MacOS/makemkvcon" \
  "/opt/homebrew/bin/makemkvcon" \
  "/usr/local/bin/makemkvcon")" || true

HANDBRAKE="$(resolve_tool_path "HandBrakeCLI" \
  "/Applications/HandBrakeCLI" \
  "/opt/homebrew/bin/HandBrakeCLI" \
  "/usr/local/bin/HandBrakeCLI")" || true

FILEBOT="$(resolve_tool_path "FileBot" \
  "/Applications/FileBot.app/Contents/MacOS/filebot" \
  "/opt/homebrew/bin/filebot" \
  "/usr/local/bin/filebot")" || true

SUBLER="$(resolve_tool_path "SublerCLI" \
  "/Applications/Subler.app/Contents/MacOS/SublerCLI" \
  "/opt/homebrew/bin/SublerCLI" \
  "/usr/local/bin/SublerCLI" \
  "/opt/homebrew/bin/sublercli" \
  "/usr/local/bin/sublercli")" || true

MISSING=()
[[ -z "$MAKEMKV" ]] && MISSING+=("MakeMKV (makemkvcon)")
[[ -z "$HANDBRAKE" ]] && MISSING+=("HandBrakeCLI")
[[ -z "$FILEBOT" ]] && MISSING+=("FileBot")
[[ -z "$SUBLER" ]] && MISSING+=("SublerCLI")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  missing_text=$(printf '• %s\n' "${MISSING[@]}")
  show_alert "Missing required tool(s):\n${missing_text}\nInstall the missing tools and run again."
  exit 1
fi

# 1) Source selection
SOURCE_KIND="$(choose_from_list "What is your source?" "Disc" "Video File")" || exit 1

if [[ "$SOURCE_KIND" == "Video File" ]]; then
  selected_files="$(choose_files "Select one or more source video files")" || exit 1
  while IFS= read -r file; do
    [[ -n "$file" ]] && SOURCE_FILES+=("$file")
  done <<< "$selected_files"

  if [[ ${#SOURCE_FILES[@]} -eq 0 ]]; then
    show_alert "No source files selected."
    exit 1
  fi
else
  DISC_TYPE="$(choose_from_list "What type of disc — DVD or Blu-ray?" "DVD" "Blu-ray")" || exit 1
  DISC_PATH="$(choose_folder "Select the mounted disc volume (typically under /Volumes)")" || exit 1
  if [[ "$DISC_TYPE" == "Blu-ray" ]]; then
    RIP_DIR="$(choose_folder "Select a folder where MakeMKV should write MKV file(s)")" || exit 1
  fi
fi

# 2) Output directory selection
OUTPUT_DIR="$(choose_folder "Select output directory for converted files, metadata files, and logs")" || exit 1
LOG_FILE="${OUTPUT_DIR%/}/conversion_log_$(date '+%Y%m%d_%H%M%S').txt"

touch "$LOG_FILE" || {
  show_alert "Cannot create log file in selected output directory: $OUTPUT_DIR"
  exit 1
}

log_line "Media Magic started"
log_line "MakeMKV path: $MAKEMKV"
log_line "HandBrake path: $HANDBRAKE"
log_line "FileBot path: $FILEBOT"
log_line "Subler path: $SUBLER"

# Version checks logged for troubleshooting cross-version CLI changes
run_and_log "version" "$MAKEMKV" --version || true
run_and_log "version" "$HANDBRAKE" --version || true
run_and_log "version" "$FILEBOT" -version || run_and_log "version" "$FILEBOT" --version || true
run_and_log "version" "$SUBLER" --help || run_and_log "version" "$SUBLER" -h || true

# Verify required HandBrake preset exists before processing
if ! "$HANDBRAKE" --preset-list 2>>"$LOG_FILE" | grep -Fq "$HANDBRAKE_PRESET"; then
  show_alert "HandBrake preset not found: ${HANDBRAKE_PRESET}\nCheck your HandBrakeCLI version / preset list."
  log_line "Required preset missing: $HANDBRAKE_PRESET"
  exit 1
fi

TOTAL_FILES=0
if [[ "$SOURCE_KIND" == "Video File" ]]; then
  TOTAL_FILES=${#SOURCE_FILES[@]}
else
  TOTAL_FILES=1
fi

process_video_file() {
  local source_path="$1"
  local index="$2"
  local total="$3"
  local source_mode="${4:-file}"
  local source_name base_name hb_output filebot_before filebot_after renamed_path
  local hb_cmd=()
  local added_count=0
  local added_file=""

  source_name="$(basename "$source_path")"
  base_name="${source_name%.*}"
  hb_output="${OUTPUT_DIR%/}/${base_name}.m4v"

  show_notification "Converting file ${index} of ${total}: ${source_name}"
  if [[ "$source_mode" == "dvd" ]]; then
    hb_cmd=( "$HANDBRAKE" -i "$source_path" -o "$hb_output" --main-feature --preset="$HANDBRAKE_PRESET" )
  else
    hb_cmd=( "$HANDBRAKE" -i "$source_path" -o "$hb_output" --preset="$HANDBRAKE_PRESET" )
  fi

  if ! run_and_log "handbrake" "${hb_cmd[@]}"; then
    show_alert "HandBrake failed for ${source_name}. Check log:\n$LOG_FILE"
    return 1
  fi

  filebot_before="$(mktemp /tmp/media_magic_before.XXXXXX)"
  filebot_after="$(mktemp /tmp/media_magic_after.XXXXXX)"
  list_media_files > "$filebot_before"

  show_notification "Renaming file ${index} of ${total}: ${source_name}"
  if ! run_and_log "filebot" "$FILEBOT" -rename "$hb_output" --db TheMovieDB --output "$OUTPUT_DIR" --action move --format "{n} ({y})"; then
    rm -f "$filebot_before" "$filebot_after"
    show_alert "FileBot failed for ${source_name}. Check log:\n$LOG_FILE"
    return 1
  fi

  list_media_files > "$filebot_after"

  renamed_path="$hb_output"
  if [[ ! -f "$renamed_path" ]]; then
    while IFS= read -r maybe_added; do
      [[ -n "$maybe_added" ]] || continue
      added_file="$maybe_added"
      added_count=$((added_count + 1))
    done < <(comm -13 "$filebot_before" "$filebot_after")

    if [[ $added_count -ge 1 && -n "${added_file:-}" ]]; then
      renamed_path="$added_file"
    else
      renamed_path="$(tail -n 1 "$filebot_after")"
    fi
  fi

  rm -f "$filebot_before" "$filebot_after"

  if [[ -z "$renamed_path" || ! -f "$renamed_path" ]]; then
    show_alert "Could not determine FileBot output for ${source_name}."
    log_line "Could not determine renamed file for source: $source_path"
    return 1
  fi

  show_notification "Embedding metadata file ${index} of ${total}: $(basename "$renamed_path")"

  # SublerCLI syntax differs between some builds; attempt two common forms.
  if ! run_and_log "subler" "$SUBLER" -source "$renamed_path" -dest "$renamed_path" -search; then
    if ! run_and_log "subler" "$SUBLER" -source "$renamed_path" -dest "$renamed_path" -metadata search; then
      show_alert "Subler failed for $(basename "$renamed_path"). Check log:\n$LOG_FILE"
      return 1
    fi
  fi

  COMPLETED_TITLES+=("$(basename "${renamed_path%.*}")")
  return 0
}

if [[ "$SOURCE_KIND" == "Disc" && "$DISC_TYPE" == "Blu-ray" ]]; then
  show_notification "Ripping Blu-ray with MakeMKV…"
  if ! run_and_log "makemkv" "$MAKEMKV" mkv "$MAKEMKV_DISC_SELECTOR" all "$RIP_DIR"; then
    show_alert "MakeMKV failed while ripping Blu-ray. Check log:\n$LOG_FILE"
    exit 1
  fi

  rip_selection="$(osascript - "$RIP_DIR" <<'APPLESCRIPT'
on run argv
  set ripDir to POSIX file (item 1 of argv)
  set selectedFile to choose file with prompt "Select the MKV produced by MakeMKV" default location ripDir
  return POSIX path of selectedFile
end run
APPLESCRIPT
)" || exit 1

  process_video_file "$rip_selection" 1 1 || true
elif [[ "$SOURCE_KIND" == "Disc" && "$DISC_TYPE" == "DVD" ]]; then
  process_video_file "$DISC_PATH" 1 1 "dvd" || true
else
  idx=1
  for source in "${SOURCE_FILES[@]}"; do
    process_video_file "$source" "$idx" "$TOTAL_FILES" || true
    idx=$((idx + 1))
  done
fi

ELAPSED="$(calc_elapsed)"
TOTAL_CONVERTED=${#COMPLETED_TITLES[@]}

if [[ $TOTAL_CONVERTED -gt 0 ]]; then
  titles_text=""
  for t in "${COMPLETED_TITLES[@]}"; do
    titles_text+="• ${t}"$'\n'
  done
else
  titles_text="(No successful outputs)"
fi

log_line "Completed conversions: $TOTAL_CONVERTED"
log_line "Elapsed: $ELAPSED"
log_line "Media Magic finished"

show_dialog "Pipeline complete.\n\nTotal converted: ${TOTAL_CONVERTED}\n\nTitles:\n${titles_text}\nElapsed: ${ELAPSED}\n\nLog file: ${LOG_FILE}"

exit 0
