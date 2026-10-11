# shellcheck shell=bash
#ddev-generated
#
# ddev-autostart plugin: launchd (macOS)
#
# Implements the plugin contract described in systemd.sh.
#
# Design:
#   - A per-user LaunchAgent in ~/Library/LaunchAgents, not a system-wide
#     LaunchDaemon. On macOS, Docker (Docker Desktop, OrbStack, Colima,
#     Rancher Desktop) runs as the logged-in user and only starts at login, so
#     projects start at login too. No sudo is needed, and registrations
#     belong to the user whose home they're in.
#   - RunAtLoad without KeepAlive: launchd runs the job once when it loads the
#     agent at login, like a oneshot systemd unit.
#   - `enable` only writes the file; it doesn't load it, since loading runs
#     the job right away. launchd loads it at the next login.
#   - The job runs bin/ddev-autostart, shipped with the add-on, with the
#     paths as arguments (never parsed by a shell). That script waits for
#     Docker, takes the start lock (one `ddev start` at a time, see its
#     comments), runs `ddev start` and writes the log. Add-on updates reach
#     every registration this way.
#   - macOS lists a login job in Login Items under the name of the file it
#     runs (a `/bin/sh -c` job showed up as "sh"). So the job starts through
#     a tiny per-project launcher, ddev-autostart-<project> in
#     ~/Library/Application Support/ddev-autostart, which only runs the
#     script it's given (`exec "$@"`). The list then says which project each
#     entry is, which matters for one left behind by a deleted project.
#   - AbandonProcessGroup: by default launchd kills whatever a job leaves
#     running when it exits, which would include processes `ddev start`
#     launches to keep running (Mutagen's daemon, for one).
#     The trade-off: if `ddev start` fails, whatever it already launched
#     isn't cleaned up by launchd either, the same as when run in Terminal.
#   - Only files carrying _LD_MARKER on line 2 are ever changed or removed.
#   - Bash 3.2 and BSD tools: this runs with macOS's /bin/bash.

DDEV_AUTOSTART_AGENT_DIR="${DDEV_AUTOSTART_AGENT_DIR:-${HOME}/Library/LaunchAgents}"
_LD_LOG_DIR="${HOME}/Library/Logs/ddev-autostart"

_LD_MARKER="<!-- Managed by ddev-autostart."
# Per-project launchers (see "Design"). They hold no logic, so they never
# need updating.
_LD_LAUNCHER_DIR="${HOME}/Library/Application Support/ddev-autostart"
_LD_LAUNCHER_MARKER="# Managed by ddev-autostart."
_LD_LAUNCHER="#!/bin/sh
${_LD_LAUNCHER_MARKER} Named after the project, so macOS Login Items shows
# which project this login job is for. Runs the add-on's login script.
exec \"\$@\""

# The login job, next to this plugin: autostart.d/bin/ddev-autostart.
_LD_JOB_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/bin/ddev-autostart"

_ld_label() { printf 'ddev-autostart.%s' "$1"; }
_ld_launcher_path() { printf '%s/ddev-autostart-%s' "$_LD_LAUNCHER_DIR" "$1"; }

# True if the launcher file was written by this add-on (marker on line 2).
_ld_launcher_is_managed() {
    local line2=""
    [ -f "$1" ] || return 1
    { IFS= read -r _ && IFS= read -r line2; } <"$1" || true
    case "$line2" in
        "$_LD_LAUNCHER_MARKER"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Removes NAME's launcher (and the folder, once empty) if its LaunchAgent is
# gone: it's only used through the plist.
_ld_drop_launcher() {
    local launcher
    launcher="$(_ld_launcher_path "$1")"
    [ ! -e "$(_ld_agent_path "$1")" ] || return 0
    if _ld_launcher_is_managed "$launcher"; then
        rm -f "$launcher"
    fi
    rmdir "$_LD_LAUNCHER_DIR" 2>/dev/null || true # only if it's now empty
}

# Writes NAME's launcher unless it's already there and current.
_ld_write_launcher() {
    local launcher tmp
    launcher="$(_ld_launcher_path "$1")"
    if [ -e "$launcher" ] && ! _ld_launcher_is_managed "$launcher"; then
        echo "❌ Error: ${launcher} exists but wasn't created by ddev autostart; leaving it alone." >&2
        return 1
    fi
    if [ -x "$launcher" ] && [ "$(cat "$launcher")" = "$_LD_LAUNCHER" ]; then
        return 0
    fi
    if ! mkdir -p "$_LD_LAUNCHER_DIR" || ! tmp="$(mktemp "${launcher}.XXXXXX")" ||
        ! printf '%s\n' "$_LD_LAUNCHER" >"$tmp" || ! chmod 0755 "$tmp" || ! mv -f "$tmp" "$launcher"; then
        [ -z "${tmp:-}" ] || rm -f "$tmp"
        echo "❌ Error: can't write ${launcher}." >&2
        return 1
    fi
}
_ld_agent_path() { printf '%s/%s.plist' "$DDEV_AUTOSTART_AGENT_DIR" "$(_ld_label "$1")"; }
_ld_log_path() { printf '%s/%s.log' "$_LD_LOG_DIR" "$1"; }
_ld_domain() { printf 'gui/%s' "$(id -u)"; }

# True if the file was written by this add-on: line 1 is the XML declaration,
# line 2 the marker.
_ld_is_managed() {
    local line2=""
    [ -f "$1" ] || return 1
    { IFS= read -r _ && IFS= read -r line2; } <"$1" || true
    case "$line2" in
        "$_LD_MARKER"*) return 0 ;;
        *) return 1 ;;
    esac
}

_ld_not_ours() {
    echo "⚠️  $1 exists but wasn't created by ddev autostart; leaving it alone." >&2
}

# Escape a value for an XML text node. sed rather than ${s//</&lt;}, where
# bash 5.2 turns '&' in the replacement into the matched text.
_ld_xml() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# A value that fits on one line of the plist.
_ld_one_line() {
    case "$1" in *$'\n'* | *$'\r'*) return 1 ;; esac
}

# Run a command with a time limit. macOS has no `timeout`; perl ships with it.
# With neither, don't run it at all (returns 125): the only caller is an
# advisory check, which must not hang.
_ld_timeout() {
    local secs="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else
        return 125
    fi
}

# Absolute path of a command as found in PATH, symlinks kept as they are:
# Homebrew points a stable path at a versioned one that upgrades delete.
_ld_find_command() {
    local bin
    bin="$(command -v "$1" 2>/dev/null)" || return 1
    case "$bin" in
        /*) ;;
        */*) bin="$(cd "$(dirname "$bin")" && pwd)/$(basename "$bin")" ;;
        *) return 1 ;; # a shell function or alias, not a file
    esac
    printf '%s\n' "$bin"
}

# The job's PATH: the folders of ddev and docker, then the standard ones.
# docker's folder also holds Docker's credential helpers, which pulls need.
# Not the terminal's PATH, for the reasons given in systemd.sh.
_ld_job_path() {
    local ddev_bin="$1" docker_bin="$2" path="" dir
    local std="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    for dir in "$(dirname "$ddev_bin")" "$(dirname "$docker_bin")"; do
        case "$dir" in /*) ;; *) continue ;; esac
        case "$dir" in *:*) continue ;; esac
        case ":${path}:${std}:" in *":${dir}:"*) continue ;; esac
        path="${path:+${path}:}${dir}"
    done
    printf '%s' "${path:+${path}:}${std}"
}

# What launchd knows about the job, from `launchctl print`:
#   unloaded | running | ok | failed | never
# Any state other than "not running" counts as running: a job being started
# shows "xpcproxy", for one.
# A job killed by a signal has "last terminating signal" instead of an exit
# code. launchctl's output isn't a stable API; it's the only source there is.
_ld_job_state() {
    local out
    out="$(launchctl print "$(_ld_domain)/$(_ld_label "$1")" 2>/dev/null)" || {
        echo unloaded
        return 0
    }
    printf '%s\n' "$out" | awk '
        /^[[:space:]]*state = / && !/state = not running/ && !done { running = 1 }
        /^[[:space:]]*state = / { done = 1 }
        /^[[:space:]]*last terminating signal = / { signaled = 1 }
        /^[[:space:]]*last exit code = / {
            code = $0; sub(/.*last exit code = /, "", code); sub(/[^0-9-].*/, "", code)
        }
        END {
            if (running) print "running"
            else if (signaled) print "failed"
            else if (code == "") print "never"
            else if (code == "0") print "ok"
            else print "failed"
        }'
}

# launchd's list of turned-off jobs. Fails if launchd couldn't be asked
# (no GUI session, for one), so callers can tell that from "none".
_ld_disabled_jobs() { launchctl print-disabled "$(_ld_domain)" 2>/dev/null; }

# True if `launchctl disable` was used on the job. macOS 13+ prints
# "LABEL" => disabled, older versions => true.
# Arguments: NAME OUTPUT-OF-_ld_disabled_jobs
_ld_is_disabled() {
    printf '%s\n' "$2" |
        awk -v l="\"$(_ld_label "$1")\"" '
            index($0, l " => ") && ($NF == "true" || $NF == "disabled") { found = 1 }
            END { exit !found }'
}

# Make sure `launchctl disable` isn't keeping the job off. `launchctl enable`
# only clears that setting (it doesn't load or run anything), so it's always
# run rather than trusting the query. WAS is what the query said: enabled,
# disabled or unknown. Returns 0 if the job is on, 1 if it's known to be off
# and stays off, 2 if neither the query nor `launchctl enable` worked, so
# whether it's on can't be known (launchd unreachable, e.g. over SSH).
_ld_turn_on() {
    local name="$1" was="$2" target
    target="$(_ld_domain)/$(_ld_label "$name")"
    launchctl enable "$target" 2>/dev/null && return 0
    case "$was" in
        enabled) return 0 ;;
        disabled)
            echo "❌ Error: ${name} is turned off with launchctl and couldn't be turned back on." >&2
            echo "   Try: launchctl enable ${target}" >&2
            return 1
            ;;
    esac
    return 2
}

_ld_unsure() {
    echo "⚠️  ${1}, but launchd couldn't be reached to make sure it isn't turned off,"
    echo "   so it may not start at login. When logged in to the Mac, run:"
    echo "     launchctl enable $(_ld_domain)/$(_ld_label "$2")"
}

# Arguments: NAME ROOT DDEV_BIN DOCKER_BIN LOG
# The job is LAUNCHER $_LD_JOB_SCRIPT DOCKER DDEV NAME LOG AGENT.
# DOCKER_HOST, DOCKER_CONTEXT, DOCKER_CONFIG and DDEV_XDG_CONFIG_HOME (where
# DDEV keeps its global config) are copied when set, as on systemd.
# HOME is set explicitly rather than relying on launchd's default.
# DDEV_NONINTERACTIVE: at login the network may not be up, so the project's
# hostname may not resolve yet; DDEV would then ask for a sudo password to edit
# /etc/hosts, which a login job can't answer, and fail (seen on macOS 26).
_ld_render_plist() {
    local name="$1" root="$2" ddev_bin="$3" docker_bin="$4" log="$5" var env=""
    for var in DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG DDEV_XDG_CONFIG_HOME; do
        if [ -n "${!var:-}" ]; then
            env="${env}
        <key>${var}</key>
        <string>$(_ld_xml "${!var}")</string>"
        fi
    done

    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- Managed by ddev-autostart. Do not edit; use ddev autostart disable instead. -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$(_ld_label "$name")</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(_ld_xml "$(_ld_launcher_path "$name")")</string>
        <string>$(_ld_xml "$_LD_JOB_SCRIPT")</string>
        <string>$(_ld_xml "$docker_bin")</string>
        <string>$(_ld_xml "$ddev_bin")</string>
        <string>${name}</string>
        <string>$(_ld_xml "$log")</string>
        <string>$(_ld_xml "$(_ld_agent_path "$name")")</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$(_ld_xml "$root")</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$(_ld_xml "$HOME")</string>
        <key>PATH</key>
        <string>$(_ld_xml "$(_ld_job_path "$ddev_bin" "$docker_bin")")</string>
        <key>DDEV_NONINTERACTIVE</key>
        <string>true</string>${env}
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>AbandonProcessGroup</key>
    <true/>
</dict>
</plist>
EOF
}

# The command to run the job now, from the file on disk. Not `kickstart`: that
# reruns the loaded copy, whose settings may be older than the file. Nothing
# while the job is running. Arguments: NAME [disabled|unknown]; a job turned
# off with launchctl can't be loaded until it's turned on.
# The unload is separated by ';' so loading still happens if the job was
# unloaded in the meantime.
_ld_try_hint() {
    local name="$1" target load
    target="$(_ld_domain)/$(_ld_label "$name")"
    load="launchctl bootstrap $(_ld_domain) \"$(_ld_agent_path "$name")\""
    case "${2:-}" in
        disabled | unknown) load="launchctl enable ${target} && ${load}" ;;
    esac
    case "$(_ld_job_state "$name")" in
        unloaded) echo "$load" ;;
        running) ;;
        *) echo "launchctl bootout ${target} 2>/dev/null; ${load}" ;;
    esac
}

plugin_enable() {
    local launcher had=""
    launcher="$(_ld_launcher_path "$1")"
    [ ! -e "$launcher" ] || had=1
    _ld_enable "$@" && return 0
    # Don't leave behind a launcher this call created that no plist runs (the
    # plist may still be missing, or one from v0.5.1 that runs /bin/sh).
    if [ -z "$had" ] &&
        ! grep -qF "<string>$(_ld_xml "$launcher")</string>" "$(_ld_agent_path "$1")" 2>/dev/null; then
        _ld_launcher_is_managed "$launcher" && rm -f "$launcher"
        rmdir "$_LD_LAUNCHER_DIR" 2>/dev/null || true
    fi
    return 1
}

_ld_enable() {
    local name="$1" root="$2"
    local agent ddev_bin docker_bin log tmp var state disabled_jobs was on stale=""

    if [ "$(id -u)" -eq 0 ]; then
        echo "❌ Error: run this as your normal user, not root (DDEV does not run as root)." >&2
        return 1
    fi
    if ! _ld_one_line "$root" || ! _ld_one_line "$HOME"; then
        echo "❌ Error: the project path or your home folder's path contains a line break." >&2
        return 1
    fi
    for var in DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG DDEV_XDG_CONFIG_HOME; do
        if [ -n "${!var:-}" ] && ! _ld_one_line "${!var}"; then
            echo "❌ Error: ${var} contains a line break." >&2
            return 1
        fi
    done
    if ! ddev_bin="$(_ld_find_command ddev)" || ! _ld_one_line "$ddev_bin"; then
        echo "❌ Error: ddev not found in PATH." >&2
        return 1
    fi
    # The login job runs `docker info` to wait for Docker. Without the docker
    # command it would wait five minutes and fail at every login, so refuse.
    if ! docker_bin="$(_ld_find_command docker)" || ! _ld_one_line "$docker_bin"; then
        echo "❌ Error: the docker command isn't in your PATH, so the login job couldn't tell when Docker is ready." >&2
        return 1
    fi

    if [ ! -x "$_LD_JOB_SCRIPT" ] || ! _ld_one_line "$_LD_JOB_SCRIPT"; then
        echo "❌ Error: the add-on's login script is missing (${_LD_JOB_SCRIPT}). Reinstall it with: ddev add-on get asiby/ddev-autostart" >&2
        return 1
    fi

    agent="$(_ld_agent_path "$name")"
    log="$(_ld_log_path "$name")"
    if [ -e "$agent" ] && ! _ld_is_managed "$agent"; then
        _ld_not_ours "$agent"
        return 1
    fi
    _ld_one_line "$_LD_LAUNCHER_DIR" || {
        echo "❌ Error: your home folder's path contains a line break." >&2
        return 1
    }
    # Before the plist, which runs it. Also restores a launcher deleted by hand.
    _ld_write_launcher "$name" || return 1

    if ! _ld_timeout 20 "$docker_bin" info >/dev/null 2>&1; then
        echo "⚠️  Warning: Docker isn't responding right now. The job will still wait for it at login."
    fi

    # Rendered next to its final place (the suffix keeps launchd from loading it),
    # then renamed, so launchd never sees half a file.
    if ! mkdir -p "$DDEV_AUTOSTART_AGENT_DIR" || ! tmp="$(mktemp "${agent}.XXXXXX")"; then
        echo "❌ Error: can't write to ${DDEV_AUTOSTART_AGENT_DIR}." >&2
        return 1
    fi
    if ! _ld_render_plist "$name" "$root" "$ddev_bin" "$docker_bin" "$log" >"$tmp"; then
        rm -f "$tmp"
        echo "❌ Error: failed to write the LaunchAgent for ${name}." >&2
        return 1
    fi
    if ! disabled_jobs="$(_ld_disabled_jobs)"; then
        was="unknown"
    elif _ld_is_disabled "$name" "$disabled_jobs"; then
        was="disabled"
    else
        was="enabled"
    fi

    if [ -f "$agent" ] && cmp -s "$tmp" "$agent"; then
        rm -f "$tmp"
        on=0
        _ld_turn_on "$name" "$was" || on=$?
        if [ "$on" -eq 1 ]; then
            return 1
        elif [ "$on" -eq 2 ]; then
            _ld_unsure "${name} is registered (${agent})" "$name"
        elif [ "$was" = "disabled" ]; then
            echo "✅ ${name} was installed but turned off; it's turned on again and will start at login."
        else
            echo "✅ ${name} is already configured to start at login (${agent})."
        fi
        return 0
    fi

    echo "Configuring a LaunchAgent for ${name}..."
    # launchd keeps using a loaded job's old settings until it's unloaded, so
    # unload it before replacing the file. If it's still idle, that runs
    # nothing, and the new file loads at the next login. A running job (waiting
    # for Docker or starting the project) is left to finish.
    state="$(_ld_job_state "$name")"
    case "$state" in
        unloaded) ;;
        running) stale=1 ;;
        *)
            if ! launchctl bootout "$(_ld_domain)/$(_ld_label "$name")" 2>/dev/null; then
                rm -f "$tmp"
                echo "❌ Error: couldn't unload the current login job to replace it; nothing was changed." >&2
                echo "   Try: launchctl bootout $(_ld_domain)/$(_ld_label "$name")" >&2
                return 1
            fi
            ;;
    esac
    # launchd ignores agents others can write to, hence 0644.
    if ! { chmod 0644 "$tmp" && mv -f "$tmp" "$agent"; }; then
        rm -f "$tmp"
        echo "❌ Error: failed to write ${agent}." >&2
        return 1
    fi
    on=0
    _ld_turn_on "$name" "$was" || on=$?
    if [ "$on" -eq 1 ]; then
        # The job was off before this too, so nothing that was running is lost.
        echo "   The new settings are saved in ${agent}; they apply once it's turned on." >&2
        return 1
    fi

    if [ "$on" -eq 2 ]; then
        _ld_unsure "${name}'s LaunchAgent is installed" "$name"
    else
        echo "✅ ${name} will start automatically when you log in."
    fi
    echo "   Agent: ${agent}"
    if [ -n "$stale" ]; then
        echo "   The login job is running right now with the previous settings; the new ones apply from the next login."
    else
        echo "   Test it now with: $(_ld_try_hint "$name" "$was")"
    fi
    echo "   Docker must also start at login (a setting in Docker Desktop and OrbStack;"
    echo "   'brew services start colima' for Colima)."
}

plugin_disable() {
    local name="$1"
    local agent log state
    agent="$(_ld_agent_path "$name")"
    log="$(_ld_log_path "$name")"

    if [ ! -f "$agent" ]; then
        _ld_drop_launcher "$name" # left behind if the plist was deleted by hand
        echo "ℹ️  ${name} is not registered for autostart; nothing to do."
        return 0
    fi
    if ! _ld_is_managed "$agent"; then
        _ld_not_ours "$agent"
        return 1
    fi

    echo "Removing the LaunchAgent for ${name}..."
    # Unloading never runs `ddev stop`, but it would kill a `ddev start` still in
    # progress, so a running job is left to finish; without the file it isn't
    # loaded again at the next login. (systemctl disable doesn't stop it either.)
    state="$(_ld_job_state "$name")"
    if [ "$state" = "running" ]; then
        echo "   The login job is running right now; it's left to finish."
    elif [ "$state" != "unloaded" ] &&
        ! launchctl bootout "$(_ld_domain)/$(_ld_label "$name")" 2>/dev/null; then
        # Removing the file is what matters: the job only runs when loaded, and
        # without the file it isn't loaded at the next login.
        echo "⚠️  Warning: couldn't unload $(_ld_label "$name"); removing the file anyway, so it won't run from the next login." >&2
    fi
    if ! rm -f "$agent"; then
        echo "❌ Error: could not remove ${agent}." >&2
        return 1
    fi
    # A running job still writes to its log; deleting it now would lose that.
    # (It has already moved on from its launcher, which only exec's.)
    [ "$state" = "running" ] || rm -f "$log"
    _ld_drop_launcher "$name"

    echo "✅ ${name} will no longer start at login. (The project itself was left running.)"
}

plugin_status() {
    local name="$1" root="$2"
    local agent log state disabled_jobs hint was=""
    agent="$(_ld_agent_path "$name")"
    log="$(_ld_log_path "$name")"

    echo "Project:   ${name}"
    echo "Approot:   ${root:-<unknown>}"
    echo "Init:      launchd (starts at login)"
    echo "Agent:     ${agent}"

    if [ ! -f "$agent" ]; then
        echo "Autostart: ❌ disabled (no agent installed)"
        return 0
    fi
    if ! _ld_is_managed "$agent"; then
        echo "Autostart: ⚠️  an agent with this name exists but wasn't created by ddev autostart"
        return 0
    fi

    if ! disabled_jobs="$(_ld_disabled_jobs)"; then
        was="unknown"
        echo "Autostart: ⚠️  agent installed; couldn't ask launchd whether it's turned off"
    elif _ld_is_disabled "$name" "$disabled_jobs"; then
        was="disabled"
        echo "Autostart: ⚠️  agent installed but turned off with launchctl"
    else
        echo "Autostart: ✅ enabled"
    fi
    state="$(_ld_job_state "$name")"
    case "$state" in
        unloaded) echo "Service:   not loaded yet (launchd loads it at the next login)" ;;
        running) echo "Service:   running (waiting for Docker or starting the project)" ;;
        ok) echo "Service:   ran at login (last result: success)" ;;
        failed) echo "Service:   ran at login (last result: failed)" ;;
        never) echo "Service:   loaded, no result yet" ;;
    esac
    hint="$(_ld_try_hint "$name" "$was")"
    [ -z "$hint" ] || echo "Try it:    ${hint}"
    if [ -f "$log" ]; then
        echo "Logs:      ${log}"
    fi
}

plugin_list_registered() {
    local f base name enabled service disabled_jobs
    disabled_jobs="$(_ld_disabled_jobs)" || disabled_jobs="?"
    for f in "$DDEV_AUTOSTART_AGENT_DIR"/ddev-autostart.*.plist; do
        [ -f "$f" ] || continue
        base="${f##*/}"
        name="${base#ddev-autostart.}"
        name="${name%.plist}"
        ddev_autostart_valid_name "$name" || continue
        _ld_is_managed "$f" || continue
        if [ "$disabled_jobs" = "?" ]; then
            enabled="unknown" # launchd couldn't be asked
        elif _ld_is_disabled "$name" "$disabled_jobs"; then
            enabled="disabled"
        else
            enabled="enabled"
        fi
        case "$(_ld_job_state "$name")" in
            ok) service="active" ;;
            failed) service="failed" ;;
            running) service="activating" ;;
            *) service="inactive" ;;
        esac
        printf '%s\t%s\t%s\n' "$name" "$enabled" "$service"
    done
}

# Optional: the Docker and DDEV settings (VAR=value lines) a registration was
# written with, so `enable --registered` can keep them instead of taking the
# current shell's. Reads the layout _ld_render_plist writes: each <key> line
# followed by its <string> line.
plugin_registered_env() {
    local agent
    agent="$(_ld_agent_path "$1")"
    _ld_is_managed "$agent" || return 0
    awk '
        want != "" {
            if (match($0, /<string>.*<\/string>/)) {
                v = substr($0, RSTART + 8, RLENGTH - 17)
                gsub(/&lt;/, "<", v); gsub(/&gt;/, ">", v); gsub(/&amp;/, "\\&", v)
                print want "=" v
            }
            want = ""
            next
        }
        /<key>(DOCKER_HOST|DOCKER_CONTEXT|DOCKER_CONFIG|DDEV_XDG_CONFIG_HOME)<\/key>/ {
            want = $0
            sub(/^[ \t]*<key>/, "", want); sub(/<\/key>.*/, "", want)
        }
    ' "$agent"
}
