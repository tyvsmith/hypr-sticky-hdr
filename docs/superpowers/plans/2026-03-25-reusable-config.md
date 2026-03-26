# Reusable Configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make hypr-sticky-hdr work out-of-box for any Hyprland user with zero config, supporting multi-monitor setups and a layered config override system.

**Architecture:** Single bash script refactored to: (1) auto-detect all monitors' SDR baselines at startup, (2) read optional INI config file + env var overrides via a 5-layer resolution chain, (3) track HDR demand per-monitor with independent state and mode switching.

**Tech Stack:** Bash 4.0+ (associative arrays), hyprctl, jq, socat

**Spec:** `docs/superpowers/specs/2026-03-25-reusable-config-design.md`

---

### File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `hypr-sticky-hdr` | Modify | Main daemon — all config, state, and logic changes |
| `config.example` | Create | Documented example config showing all options |
| `install.sh` | Modify | Add config path message, install config.example |
| `README.md` | Modify | Update docs for new config system and multi-monitor |

---

### Task 1: Add INI Config Parser and Config Resolution

**Files:**
- Modify: `hypr-sticky-hdr` (lines 19-33, add new functions after line 55)

This task adds the config parsing infrastructure without changing any existing behavior. All new functions, no existing code modified yet.

- [ ] **Step 1: Replace hardcoded config vars with app defaults**

Replace the current configuration block (lines 19-33) with app defaults using a consistent naming scheme:

```bash
# --- App Defaults (universal, do not edit) ------------------------------------

CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/hypr-sticky-hdr/config"

declare -A APP_DEFAULTS=(
    [hdr_cm]="hdr"
    [hdr_brightness]="1.0"
    [hdr_bitdepth]="10"
    [sdr_cm]="auto"
    [sdr_brightness]="1.0"
    [cooldown]="2"
    [debounce]="0.2"
    [hdr_env_vars]="PROTON_ENABLE_HDR=1,HYPR_STICKY_HDR=1"
    [enabled]="1"
)

declare -A GLOBAL_CONFIG=()
# Per-monitor configs stored as MON_CFG_<normalized_name> associative arrays
```

- [ ] **Step 2: Add monitor name normalization function**

Add after the `log()` function:

```bash
normalize_monitor_name() {
    local name="$1"
    echo "$name" | tr '[:lower:]-' '[:upper:]_'
}
```

- [ ] **Step 3: Add INI config file parser**

Add the `parse_config_file()` function:

```bash
parse_config_file() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    local current_section=""
    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))
        # Strip leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        # Skip empty lines and comments
        [[ -z "$line" || "$line" == \#* ]] && continue
        # Section header
        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            local norm
            norm=$(normalize_monitor_name "$current_section")
            declare -gA "MON_CFG_${norm}"
            continue
        fi
        # Key=value
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            # Trim whitespace around key and value
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            val="${val#"${val%%[![:space:]]*}"}"
            val="${val%"${val##*[![:space:]]}"}"
            if [[ -z "$current_section" ]]; then
                GLOBAL_CONFIG["$key"]="$val"
            else
                local norm
                norm=$(normalize_monitor_name "$current_section")
                local -n arr="MON_CFG_${norm}"
                arr["$key"]="$val"
            fi
        else
            log "Warning: config line $line_num: unrecognized format: $line"
        fi
    done < "$CONFIG_FILE"
    log "Config loaded from $CONFIG_FILE"
}
```

- [ ] **Step 4: Add config resolution function**

Add the `resolve_config()` function that walks the 5-layer priority chain:

```bash
resolve_config() {
    local monitor="$1"
    local key="$2"

    # Layer 1: Per-monitor env var
    if [[ -n "$monitor" ]]; then
        local norm
        norm=$(normalize_monitor_name "$monitor")
        local env_key="HYPR_STICKY_HDR_${norm}_${key^^}"
        if [[ -n "${!env_key+x}" ]]; then
            echo "${!env_key}"
            return
        fi
    fi

    # Layer 2: Per-monitor config file
    if [[ -n "$monitor" ]]; then
        local norm
        norm=$(normalize_monitor_name "$monitor")
        local arr_name="MON_CFG_${norm}"
        if declare -p "$arr_name" &>/dev/null; then
            local -n arr="$arr_name"
            if [[ -n "${arr[$key]+x}" ]]; then
                echo "${arr[$key]}"
                return
            fi
        fi
    fi

    # Layer 3: Global env var
    local env_key="HYPR_STICKY_HDR_${key^^}"
    if [[ -n "${!env_key+x}" ]]; then
        echo "${!env_key}"
        return
    fi

    # Layer 4: Global config file
    if [[ -n "${GLOBAL_CONFIG[$key]+x}" ]]; then
        echo "${GLOBAL_CONFIG[$key]}"
        return
    fi

    # Layer 5: App default
    echo "${APP_DEFAULTS[$key]:-}"
}
```

- [ ] **Step 5: Verify the script still starts**

Run: `bash -n hypr-sticky-hdr`
Expected: No syntax errors (exit 0)

- [ ] **Step 6: Commit**

```bash
git add hypr-sticky-hdr
git commit -m "feat: add INI config parser and layered config resolution"
```

---

### Task 2: Multi-Monitor Baseline Detection

**Files:**
- Modify: `hypr-sticky-hdr` (replace `read_monitor` function and state variables)

Replace the single-monitor `read_monitor()` with multi-monitor baseline capture, and convert scalar state to per-monitor associative arrays.

- [ ] **Step 1: Replace scalar state with per-monitor arrays**

Replace the state block (lines 42-49 in original) with:

```bash
# --- State -------------------------------------------------------------------

declare -A MON_GAME_COUNT=()
declare -A MON_MANUAL_ON=()
declare -A MON_CURRENT_MODE=()
declare -A MON_COOLDOWN_PID=()
declare -A MON_ENABLED=()
declare -A MON_SDR_BASELINE=()
declare -A MON_LAST_GAME_LIST=()
DEBOUNCE_PID=""
declare -A PID_CACHE=()
ALL_MONITORS=()

CMD_FIFO="/tmp/hypr-sticky-hdr-${UID}.fifo"
REPLY_DIR="/tmp/hypr-sticky-hdr-${UID}-replies"
HYPR_SOCKET="/run/user/${UID}/hypr/${HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"
```

- [ ] **Step 2: Replace `read_monitor` with `read_all_monitors`**

Replace the `read_monitor()` function with:

```bash
read_all_monitors() {
    local json
    json=$(hyprctl monitors -j 2>/dev/null) || { log "Failed to read monitors"; return 1; }
    local count
    count=$(echo "$json" | jq 'length')
    ALL_MONITORS=()

    local i=0
    while [[ $i -lt $count ]]; do
        local fields
        fields=$(echo "$json" | jq -r --argjson idx "$i" '
            .[$idx] |
            "\(.name)\t\(.width)\t\(.height)\t\(.refreshRate)\t\(.scale)\t\(.transform)\t\(if .vrr then "1" else "0" end)\t\(.colorManagementPreset)\t\(.sdrBrightness)\t\(.sdrSaturation)\t\(.currentFormat)"
        ') || { i=$((i + 1)); continue; }
        local name width height rate scale transform vrr cm sdrb sdrs fmt
        IFS=$'\t' read -r name width height rate scale transform vrr cm sdrb sdrs fmt <<< "$fields"

        ALL_MONITORS+=("$name")

        # Build baseline string
        local bitdepth=8
        if [[ "$fmt" == *"2101010"* || "$fmt" == *"1010102"* ]]; then bitdepth=10; fi
        local baseline="${name},${width}x${height}@${rate},auto,${scale}"
        baseline+=",bitdepth,${bitdepth},vrr,${vrr}"
        if [[ "$transform" != "0" ]]; then baseline+=",transform,${transform}"; fi
        baseline+=",sdrsaturation,${sdrs}"
        baseline+=",cm,${cm},sdrbrightness,${sdrb}"
        MON_SDR_BASELINE["$name"]="$baseline"

        # Detect current mode
        if [[ "$cm" == "hdr" ]]; then
            MON_CURRENT_MODE["$name"]="hdr"
            log "Warning: $name already in HDR mode at startup"
        else
            MON_CURRENT_MODE["$name"]="sdr"
        fi

        # Initialize per-monitor state
        MON_GAME_COUNT["$name"]=0
        MON_MANUAL_ON["$name"]=0
        MON_COOLDOWN_PID["$name"]=""
        MON_LAST_GAME_LIST["$name"]=""

        # Resolve enabled flag
        local enabled
        enabled=$(resolve_config "$name" "enabled")
        MON_ENABLED["$name"]="${enabled:-1}"

        log "Monitor: $name ${width}x${height}@${rate} bitdepth=${bitdepth} cm=${cm} sdrB=${sdrb} enabled=${MON_ENABLED[$name]}"
        i=$((i + 1))
    done

    [[ ${#ALL_MONITORS[@]} -gt 0 ]] || { log "No monitors detected"; return 1; }
}
```

- [ ] **Step 3: Verify syntax**

Run: `bash -n hypr-sticky-hdr`
Expected: No syntax errors

- [ ] **Step 4: Commit**

```bash
git add hypr-sticky-hdr
git commit -m "feat: multi-monitor baseline detection and per-monitor state"
```

---

### Task 3: Per-Monitor Mode Switching

**Files:**
- Modify: `hypr-sticky-hdr` (replace `build_monitor_string`, `switch_hdr`, `switch_sdr`, `hdr_demand`, `cancel_cooldown`, `start_cooldown`)

- [ ] **Step 1: Replace `build_monitor_string` with per-monitor version**

```bash
build_monitor_string() {
    local monitor="$1"
    local mode="$2"

    # Check escape hatch first
    local escape
    escape=$(resolve_config "$monitor" "hdr_monitor_conf")
    if [[ -n "$escape" && "$mode" == "hdr" ]]; then
        echo "$escape"
        return
    fi

    if [[ "$mode" == "hdr" ]]; then
        local baseline="${MON_SDR_BASELINE[$monitor]}"
        local cm sdrb bitdepth
        cm=$(resolve_config "$monitor" "hdr_cm")
        sdrb=$(resolve_config "$monitor" "hdr_brightness")
        bitdepth=$(resolve_config "$monitor" "hdr_bitdepth")
        # Replace cm, sdrbrightness, and bitdepth in baseline
        local result="$baseline"
        result=$(echo "$result" | sed -E "s/,cm,[^,]+/,cm,${cm}/")
        result=$(echo "$result" | sed -E "s/,sdrbrightness,[^,]+/,sdrbrightness,${sdrb}/")
        result=$(echo "$result" | sed -E "s/,bitdepth,[^,]+/,bitdepth,${bitdepth}/")
        echo "$result"
    else
        echo "${MON_SDR_BASELINE[$monitor]}"
    fi
}
```

- [ ] **Step 2: Replace `hdr_demand` with per-monitor version**

```bash
hdr_demand() {
    local monitor="$1"
    echo $(( ${MON_GAME_COUNT[$monitor]:-0} + ${MON_MANUAL_ON[$monitor]:-0} ))
}
```

- [ ] **Step 3: Replace `switch_hdr` and `switch_sdr` with per-monitor versions**

```bash
switch_hdr() {
    local monitor="$1"
    [[ "${MON_CURRENT_MODE[$monitor]}" == "hdr" ]] && return
    local mon_str
    mon_str=$(build_monitor_string "$monitor" "hdr")
    log "[$monitor] Switching to HDR"
    hyprctl keyword render:cm_auto_hdr 0 >/dev/null
    hyprctl keyword monitor "$mon_str" >/dev/null
    notify-send -t 3000 "Sticky HDR" "[$monitor] HDR enabled" 2>/dev/null || true
    MON_CURRENT_MODE["$monitor"]="hdr"
}

switch_sdr() {
    local monitor="$1"
    [[ "${MON_CURRENT_MODE[$monitor]}" == "sdr" ]] && return
    local mon_str
    mon_str=$(build_monitor_string "$monitor" "sdr")
    log "[$monitor] Switching to SDR"
    hyprctl keyword monitor "$mon_str" >/dev/null
    # Only re-enable auto_hdr if no other monitors are in HDR
    local any_hdr=0
    for m in "${ALL_MONITORS[@]}"; do
        if [[ "$m" != "$monitor" && "${MON_CURRENT_MODE[$m]}" == "hdr" ]]; then
            any_hdr=1
            break
        fi
    done
    if [[ "$any_hdr" -eq 0 ]]; then
        hyprctl keyword render:cm_auto_hdr 2 >/dev/null
    fi
    notify-send -t 3000 "Sticky HDR" "[$monitor] HDR disabled" 2>/dev/null || true
    MON_CURRENT_MODE["$monitor"]="sdr"
}
```

- [ ] **Step 4: Replace `cancel_cooldown` and `start_cooldown` with per-monitor versions**

```bash
cancel_cooldown() {
    local monitor="$1"
    local pid="${MON_COOLDOWN_PID[$monitor]:-}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        MON_COOLDOWN_PID["$monitor"]=""
    fi
}

start_cooldown() {
    local monitor="$1"
    cancel_cooldown "$monitor"
    local cd_secs
    cd_secs=$(resolve_config "$monitor" "cooldown")
    ( sleep "$cd_secs"; echo "CMD:__cooldown__:${monitor}" > "$CMD_FIFO" 2>/dev/null || true ) &
    MON_COOLDOWN_PID["$monitor"]=$!
    log "[$monitor] Cooldown started (${cd_secs}s)"
}
```

- [ ] **Step 5: Verify syntax**

Run: `bash -n hypr-sticky-hdr`
Expected: No syntax errors

- [ ] **Step 6: Commit**

```bash
git add hypr-sticky-hdr
git commit -m "feat: per-monitor mode switching with config resolution"
```

---

### Task 4: Per-Monitor Window Scanning

**Files:**
- Modify: `hypr-sticky-hdr` (replace `scan_windows`, update `is_hdr_pid` to use resolved env vars)

- [ ] **Step 1: Update `is_hdr_pid` to use resolved config**

```bash
is_hdr_pid() {
    local pid="$1"
    [[ -n "$pid" && "$pid" != "null" ]] || return 1
    if [[ -n "${PID_CACHE[$pid]+x}" ]]; then
        [[ "${PID_CACHE[$pid]}" == "hdr" ]]; return
    fi
    if [[ -r "/proc/$pid/environ" ]]; then
        local env
        env=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null) || { PID_CACHE[$pid]="no"; return 1; }
        local hdr_vars_str
        hdr_vars_str=$(resolve_config "" "hdr_env_vars")
        IFS=',' read -ra hdr_vars <<< "$hdr_vars_str"
        for var in "${hdr_vars[@]}"; do
            if echo "$env" | grep -qx "$var"; then
                PID_CACHE[$pid]="hdr"
                return 0
            fi
        done
    fi
    PID_CACHE[$pid]="no"
    return 1
}
```

- [ ] **Step 2: Replace `scan_windows` with per-monitor version**

```bash
scan_windows() {
    local clients
    clients=$(hyprctl clients -j 2>/dev/null) || return

    # Count HDR windows per monitor
    declare -A new_counts=()
    declare -A new_lists=()
    for m in "${ALL_MONITORS[@]}"; do
        new_counts["$m"]=0
        new_lists["$m"]=""
    done

    while IFS=$'\t' read -r addr class pid mon; do
        [[ -n "$mon" ]] || continue
        [[ "${MON_ENABLED[$mon]:-0}" == "1" ]] || continue
        if is_hdr_pid "$pid"; then
            new_counts["$mon"]=$(( ${new_counts[$mon]:-0} + 1 ))
            new_lists["$mon"]+="  ${class} (${addr})"$'\n'
        fi
    done < <(echo "$clients" | jq -r '.[] | "\(.address)\t\(.class)\t\(.pid)\t\(.monitor)"')

    # Process demand changes per monitor
    for m in "${ALL_MONITORS[@]}"; do
        [[ "${MON_ENABLED[$m]}" == "1" ]] || continue
        local prev_demand new_demand
        prev_demand=$(hdr_demand "$m")
        MON_GAME_COUNT["$m"]=${new_counts[$m]:-0}
        MON_LAST_GAME_LIST["$m"]="${new_lists[$m]:-}"
        new_demand=$(hdr_demand "$m")

        if [[ "$new_demand" -gt 0 && "$prev_demand" -eq 0 ]]; then
            log "[$m] HDR demand started (detected=${MON_GAME_COUNT[$m]})"
            cancel_cooldown "$m"
            switch_hdr "$m"
        elif [[ "$new_demand" -eq 0 && "$prev_demand" -gt 0 ]]; then
            log "[$m] HDR demand ended"
            prune_pid_cache
            start_cooldown "$m"
        elif [[ "$new_demand" -gt 0 ]]; then
            cancel_cooldown "$m"
        fi
    done
}
```

- [ ] **Step 3: Update `schedule_scan` to use resolved debounce**

```bash
schedule_scan() {
    cancel_debounce
    local db_secs
    db_secs=$(resolve_config "" "debounce")
    ( sleep "$db_secs"; echo "CMD:__scan__:" > "$CMD_FIFO" 2>/dev/null || true ) &
    DEBOUNCE_PID=$!
}
```

- [ ] **Step 4: Verify syntax**

Run: `bash -n hypr-sticky-hdr`
Expected: No syntax errors

- [ ] **Step 5: Commit**

```bash
git add hypr-sticky-hdr
git commit -m "feat: per-monitor window scanning with config-driven env vars"
```

---

### Task 5: Update CLI Commands and Daemon Loop

**Files:**
- Modify: `hypr-sticky-hdr` (update `handle_command`, `run_daemon`, `send_command`, and main case)

- [ ] **Step 1: Update `handle_command` for per-monitor commands and reload**

```bash
handle_command() {
    local cmd="$1"
    local extra="${2:-}"
    local output=""
    local reply_file=""
    if [[ -n "$extra" && -p "$REPLY_DIR/$extra" ]]; then
        reply_file="$REPLY_DIR/$extra"
    fi
    # Extra may contain monitor:reply_id
    local target_monitor=""
    local reply_id="$extra"
    if [[ "$extra" == *:* && "$cmd" != "__window__" && "$cmd" != "__scan__" && "$cmd" != "__cooldown__" ]]; then
        target_monitor="${extra%%:*}"
        reply_id="${extra#*:}"
        if [[ -n "$reply_id" && -p "$REPLY_DIR/$reply_id" ]]; then
            reply_file="$REPLY_DIR/$reply_id"
        fi
    fi

    case "$cmd" in
        status)
            if [[ -n "$target_monitor" ]]; then
                local m="$target_monitor"
                output="[$m] display=${MON_CURRENT_MODE[$m]:-unknown} detected=${MON_GAME_COUNT[$m]:-0} manual=${MON_MANUAL_ON[$m]:-0} enabled=${MON_ENABLED[$m]:-0}"
                if [[ -n "${MON_LAST_GAME_LIST[$m]:-}" ]]; then
                    output+=$'\n'"${MON_LAST_GAME_LIST[$m]}"
                fi
            else
                output=""
                for m in "${ALL_MONITORS[@]}"; do
                    output+="[$m] display=${MON_CURRENT_MODE[$m]:-unknown} detected=${MON_GAME_COUNT[$m]:-0} manual=${MON_MANUAL_ON[$m]:-0} enabled=${MON_ENABLED[$m]:-0}"$'\n'
                    if [[ -n "${MON_LAST_GAME_LIST[$m]:-}" ]]; then
                        output+="${MON_LAST_GAME_LIST[$m]}"
                    fi
                done
            fi
            ;;
        on)
            local monitors=()
            if [[ -n "$target_monitor" ]]; then
                monitors=("$target_monitor")
            else
                for m in "${ALL_MONITORS[@]}"; do
                    [[ "${MON_ENABLED[$m]}" == "1" ]] && monitors+=("$m")
                done
            fi
            for m in "${monitors[@]}"; do
                MON_MANUAL_ON["$m"]=1
                cancel_cooldown "$m"
                switch_hdr "$m"
            done
            output="HDR on (${monitors[*]})"
            ;;
        off)
            local monitors=()
            if [[ -n "$target_monitor" ]]; then
                monitors=("$target_monitor")
            else
                for m in "${ALL_MONITORS[@]}"; do
                    [[ "${MON_ENABLED[$m]}" == "1" ]] && monitors+=("$m")
                done
            fi
            for m in "${monitors[@]}"; do
                MON_MANUAL_ON["$m"]=0
                if [[ "$(hdr_demand "$m")" -eq 0 ]]; then
                    start_cooldown "$m"
                fi
            done
            output="HDR manual off (${monitors[*]})"
            ;;
        reload)
            GLOBAL_CONFIG=()
            parse_config_file
            # Re-capture baselines for monitors currently in SDR
            local json
            json=$(hyprctl monitors -j 2>/dev/null) || true
            for m in "${ALL_MONITORS[@]}"; do
                if [[ "${MON_CURRENT_MODE[$m]}" == "sdr" ]]; then
                    local fields
                    fields=$(echo "$json" | jq -r --arg name "$m" '
                        .[] | select(.name == $name) |
                        "\(.name)\t\(.width)\t\(.height)\t\(.refreshRate)\t\(.scale)\t\(.transform)\t\(if .vrr then "1" else "0" end)\t\(.colorManagementPreset)\t\(.sdrBrightness)\t\(.sdrSaturation)\t\(.currentFormat)"
                    ') || continue
                    local name width height rate scale transform vrr cm sdrb sdrs fmt
                    IFS=$'\t' read -r name width height rate scale transform vrr cm sdrb sdrs fmt <<< "$fields"
                    local bitdepth=8
                    if [[ "$fmt" == *"2101010"* || "$fmt" == *"1010102"* ]]; then bitdepth=10; fi
                    local baseline="${name},${width}x${height}@${rate},auto,${scale}"
                    baseline+=",bitdepth,${bitdepth},vrr,${vrr}"
                    if [[ "$transform" != "0" ]]; then baseline+=",transform,${transform}"; fi
                    baseline+=",sdrsaturation,${sdrs}"
                    baseline+=",cm,${cm},sdrbrightness,${sdrb}"
                    MON_SDR_BASELINE["$name"]="$baseline"
                fi
                local enabled
                enabled=$(resolve_config "$m" "enabled")
                MON_ENABLED["$m"]="${enabled:-1}"
            done
            output="Config reloaded"
            ;;
        __window__)
            # Check if any enabled monitor has zero demand before skipping
            if [[ "$extra" == "close" ]]; then
                local any_demand=0
                for m in "${ALL_MONITORS[@]}"; do
                    [[ "${MON_ENABLED[$m]}" == "1" ]] || continue
                    if [[ "$(hdr_demand "$m")" -gt 0 ]]; then
                        any_demand=1
                        break
                    fi
                done
                [[ "$any_demand" -eq 0 ]] && return
            fi
            schedule_scan
            return
            ;;
        __scan__)
            DEBOUNCE_PID=""
            scan_windows
            return
            ;;
        __cooldown__)
            local mon="$extra"
            MON_COOLDOWN_PID["$mon"]=""
            if [[ "$(hdr_demand "$mon")" -eq 0 ]]; then
                log "[$mon] Cooldown expired, switching to SDR"
                switch_sdr "$mon"
            fi
            return
            ;;
        *)
            output="Unknown command: $cmd"
            ;;
    esac

    log "$output"
    if [[ -n "$reply_file" ]]; then
        echo "$output" > "$reply_file"
    fi
}
```

- [ ] **Step 2: Update `run_daemon` to use new init functions**

Replace the `run_daemon()` function:

```bash
run_daemon() {
    if [[ -p "$CMD_FIFO" ]]; then
        if echo "CMD:status:" > "$CMD_FIFO" 2>/dev/null; then
            log "Daemon already running. Remove $CMD_FIFO to force."
            exit 1
        fi
    fi

    rm -f "$CMD_FIFO"
    mkfifo "$CMD_FIFO"
    mkdir -p "$REPLY_DIR"

    cleanup() {
        log "Shutting down"
        rm -f "$CMD_FIFO"
        rm -rf "$REPLY_DIR"
        for m in "${ALL_MONITORS[@]}"; do
            cancel_cooldown "$m"
        done
        cancel_debounce
        jobs -p | xargs -r kill 2>/dev/null || true
        wait 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    parse_config_file
    read_all_monitors || { log "Failed to read monitor config"; exit 1; }
    log "Daemon starting (monitors: ${ALL_MONITORS[*]})"

    (
        socat -u UNIX-CONNECT:"$HYPR_SOCKET" - 2>/dev/null | while IFS= read -r line; do
            case "$line" in
                openwindow\>\>*)  echo "CMD:__window__:open" > "$CMD_FIFO" 2>/dev/null || break ;;
                closewindow\>\>*) echo "CMD:__window__:close" > "$CMD_FIFO" 2>/dev/null || break ;;
            esac
        done
        log "Event listener disconnected"
        echo "CMD:__shutdown__:" > "$CMD_FIFO" 2>/dev/null || true
    ) &

    ( while true; do sleep 30; echo "CMD:__scan__:" > "$CMD_FIFO" 2>/dev/null || break; done ) &

    exec 3<>"$CMD_FIFO"

    while IFS= read -r line <&3; do
        case "$line" in
            CMD:*:*)
                local payload="${line#CMD:}"
                local cmd="${payload%%:*}"
                local extra="${payload#*:}"
                if [[ "$cmd" == "__shutdown__" ]]; then
                    log "Event listener lost, exiting"
                    break
                fi
                handle_command "$cmd" "$extra"
                ;;
        esac
    done
}
```

- [ ] **Step 3: Update `send_command` and main case for monitor argument and reload**

```bash
send_command() {
    local cmd="$1"
    local monitor="${2:-}"
    if [[ ! -p "$CMD_FIFO" ]]; then
        echo "Daemon not running" >&2
        exit 1
    fi
    local reply_id="$$"
    local reply_fifo="$REPLY_DIR/$reply_id"
    mkdir -p "$REPLY_DIR"
    rm -f "$reply_fifo"
    mkfifo "$reply_fifo"
    local payload
    if [[ -n "$monitor" ]]; then
        payload="CMD:${cmd}:${monitor}:${reply_id}"
    else
        payload="CMD:${cmd}:${reply_id}"
    fi
    echo "$payload" > "$CMD_FIFO" 2>/dev/null || {
        echo "Failed to send command" >&2
        rm -f "$reply_fifo"
        exit 1
    }
    local reply
    if reply=$(timeout 3 cat "$reply_fifo" 2>/dev/null); then
        echo "$reply"
    else
        echo "Timeout waiting for reply" >&2
    fi
    rm -f "$reply_fifo"
}

# --- Main --------------------------------------------------------------------

case "${1:-}" in
    daemon) run_daemon ;;
    on)     send_command "on" "${2:-}" ;;
    off)    send_command "off" "${2:-}" ;;
    status) send_command "status" "${2:-}" ;;
    reload) send_command "reload" ;;
    *)
        echo "Usage: hypr-sticky-hdr {daemon|on|off|status|reload} [monitor]"
        exit 1
        ;;
esac
```

- [ ] **Step 4: Update script header comment**

```bash
# =============================================================================
# hypr-sticky-hdr — Sticky HDR for Hyprland
#
# Daemon that auto-detects HDR windows by scanning process env vars and keeps
# the monitor in HDR mode for the process's entire lifetime — no flickering
# on alt-tab. Supports multi-monitor setups with per-monitor configuration.
#
# Usage:
#   hypr-sticky-hdr daemon           Start the daemon (use in autostart.conf)
#   hypr-sticky-hdr on [monitor]     Manual HDR on
#   hypr-sticky-hdr off [monitor]    Manual HDR off
#   hypr-sticky-hdr status [monitor] Print current state
#   hypr-sticky-hdr reload           Reload config file
#
# Config: ~/.config/hypr-sticky-hdr/config (optional)
# =============================================================================
```

- [ ] **Step 5: Verify syntax**

Run: `bash -n hypr-sticky-hdr`
Expected: No syntax errors

- [ ] **Step 6: Commit**

```bash
git add hypr-sticky-hdr
git commit -m "feat: per-monitor CLI commands, reload, and updated daemon loop"
```

---

### Task 6: Example Config and Install Updates

**Files:**
- Create: `config.example`
- Modify: `install.sh`

- [ ] **Step 1: Create `config.example`**

```ini
# hypr-sticky-hdr configuration
# Place this file at: ~/.config/hypr-sticky-hdr/config
#
# All settings are optional. The daemon works out-of-box with no config.
# Environment variables override config file values (see README.md).

# --- Global Settings ---------------------------------------------------------

# Seconds to wait before switching back to SDR after last HDR window closes
# cooldown=2

# Seconds to debounce rapid window open/close events
# debounce=0.2

# Comma-separated list of env vars that trigger HDR detection
# hdr_env_vars=PROTON_ENABLE_HDR=1,HYPR_STICKY_HDR=1

# Default HDR mode settings (applied to all monitors unless overridden)
# hdr_brightness=1.0
# hdr_cm=hdr
# hdr_bitdepth=10

# Default SDR mode settings
# sdr_brightness=1.0
# sdr_cm=auto

# --- Per-Monitor Overrides ---------------------------------------------------
# Use [monitor-name] sections to override settings for specific monitors.
# Monitor names match hyprctl monitors output (e.g., DP-1, HDMI-A-1).

# [DP-1]
# hdr_brightness=1.35
# enabled=1

# [HDMI-A-1]
# enabled=0

# --- Escape Hatch ------------------------------------------------------------
# For advanced users: provide a raw Hyprland monitor config string.
# When set, this is used verbatim instead of the constructed string.
#
# [DP-1]
# hdr_monitor_conf=DP-1,2560x1440@165,auto,1,bitdepth,10,vrr,1,cm,hdr,sdrbrightness,1.35
```

- [ ] **Step 2: Update `install.sh` to mention config and install example**

Replace the `main()` function in `install.sh`:

```bash
main() {
    mkdir -p "$INSTALL_DIR"

    # If run from a clone, use the local file; otherwise fetch from GitHub
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$script_dir/$SCRIPT_NAME" ]]; then
        echo "Installing from local copy..."
        cp "$script_dir/$SCRIPT_NAME" "$INSTALL_DIR/$SCRIPT_NAME"
    else
        echo "Downloading from GitHub..."
        curl -fsSL "https://raw.githubusercontent.com/$REPO/main/$SCRIPT_NAME" \
            -o "$INSTALL_DIR/$SCRIPT_NAME"
    fi

    chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
    echo "Installed $SCRIPT_NAME to $INSTALL_DIR/"

    # Install example config if no config exists
    local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/hypr-sticky-hdr"
    if [[ ! -f "$config_dir/config" ]]; then
        mkdir -p "$config_dir"
        if [[ -f "$script_dir/config.example" ]]; then
            cp "$script_dir/config.example" "$config_dir/config.example"
        else
            curl -fsSL "https://raw.githubusercontent.com/$REPO/main/config.example" \
                -o "$config_dir/config.example" 2>/dev/null || true
        fi
    fi

    # Add to Hyprland autostart if not already present
    if [[ -d "$HOME/.config/hypr" ]]; then
        touch "$AUTOSTART_FILE"
        if ! grep -qF "$SCRIPT_NAME daemon" "$AUTOSTART_FILE"; then
            echo "$AUTOSTART_LINE" >> "$AUTOSTART_FILE"
            echo "Added to $AUTOSTART_FILE"
        else
            echo "Already in $AUTOSTART_FILE"
        fi
    else
        echo "Hyprland config not found — add this to your autostart manually:"
        echo "  $AUTOSTART_LINE"
    fi

    # Verify PATH
    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
        echo ""
        echo "Warning: $INSTALL_DIR is not in your PATH."
        echo "Add it to your shell config, e.g.:"
        echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    fi

    echo ""
    echo "Done. Start with: hypr-sticky-hdr daemon"
    echo "Optional config:  $config_dir/config"
    echo "Example config:   $config_dir/config.example"
}
```

- [ ] **Step 3: Commit**

```bash
git add config.example install.sh
git commit -m "feat: add example config and update installer"
```

---

### Task 7: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite README.md**

```markdown
# hypr-sticky-hdr

Sticky HDR daemon for [Hyprland](https://hyprland.org/). Auto-detects HDR windows by scanning process environment variables and keeps the monitor in HDR mode for the process's entire lifetime — no flickering on alt-tab. Supports multi-monitor setups.

## How it works

When a window opens, the daemon checks if its process has `PROTON_ENABLE_HDR=1` or `HYPR_STICKY_HDR=1` in its environment. If so, HDR is enabled on that window's monitor and stays on until all HDR windows on that monitor close (plus a short cooldown to avoid flicker).

**Key behaviors:**
- Listens to Hyprland IPC events for window open/close
- Debounced scanning (200ms) to batch rapid events
- Cooldown (2s) before switching back to SDR after the last HDR window closes
- Periodic background scan (30s) as a safety net
- PID-based caching so `/proc` reads happen only once per process
- Per-monitor HDR tracking — only the monitor with HDR windows switches
- Auto-detects SDR baseline at startup — restores exact original settings

## Dependencies

- `hyprctl` (comes with Hyprland)
- `socat` — for Hyprland IPC socket
- `jq` — JSON parsing
- `notify-send` — optional desktop notifications

## Installation

One-liner (downloads the script and adds Hyprland autostart):

```bash
curl -fsSL https://raw.githubusercontent.com/tyvsmith/hypr-sticky-hdr/main/install.sh | bash
```

Or clone and run:

```bash
git clone https://github.com/tyvsmith/hypr-sticky-hdr.git
cd hypr-sticky-hdr
./install.sh
```

This installs `hypr-sticky-hdr` to `~/.local/bin/` and adds `exec-once = hypr-sticky-hdr daemon` to `~/.config/hypr/autostart.conf`.

## Usage

```bash
hypr-sticky-hdr daemon           # Start the daemon
hypr-sticky-hdr on [monitor]     # Force HDR on (all monitors or specific)
hypr-sticky-hdr off [monitor]    # Release manual override
hypr-sticky-hdr status [monitor] # Show current state
hypr-sticky-hdr reload           # Reload config file
```

## Configuration

The daemon works out-of-box with zero configuration. All monitors are auto-detected and managed with sane defaults.

To customize, create `~/.config/hypr-sticky-hdr/config` (an example is installed at `config.example` in the same directory):

```ini
# Global settings
cooldown=3
hdr_brightness=1.2

# Per-monitor overrides
[DP-1]
hdr_brightness=1.35

[HDMI-A-1]
enabled=0
```

### Available options

| Key | Scope | Default | Description |
|-----|-------|---------|-------------|
| `hdr_brightness` | global, per-monitor | `1.0` | SDR content brightness when in HDR mode |
| `hdr_cm` | global, per-monitor | `hdr` | Color management preset for HDR mode |
| `hdr_bitdepth` | global, per-monitor | `10` | Bit depth in HDR mode |
| `sdr_brightness` | global, per-monitor | `1.0` | Brightness in SDR mode |
| `sdr_cm` | global, per-monitor | `auto` | Color management preset for SDR mode |
| `cooldown` | global | `2` | Seconds before switching back to SDR |
| `debounce` | global | `0.2` | Seconds to debounce window events |
| `hdr_env_vars` | global | `PROTON_ENABLE_HDR=1,HYPR_STICKY_HDR=1` | Env vars that trigger HDR detection |
| `enabled` | per-monitor | `1` | Whether to manage this monitor (`0` to disable) |
| `hdr_monitor_conf` | per-monitor | — | Raw Hyprland monitor string (escape hatch) |

### Environment variable overrides

Environment variables take priority over the config file. Use the prefix `HYPR_STICKY_HDR_` followed by the key name in uppercase:

```bash
# Global override
export HYPR_STICKY_HDR_COOLDOWN=5

# Per-monitor override (monitor name: uppercase, hyphens become underscores)
export HYPR_STICKY_HDR_DP_1_BRIGHTNESS=1.35
export HYPR_STICKY_HDR_HDMI_A_1_ENABLED=0
```

### Priority order (highest to lowest)

1. Per-monitor environment variable
2. Per-monitor config file section
3. Global environment variable
4. Global config file value
5. App default

## Triggering HDR for non-Proton apps

Set the environment variable before launching:

```bash
HYPR_STICKY_HDR=1 some-hdr-app
```

## License

MIT
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update README for multi-monitor and config system"
```
