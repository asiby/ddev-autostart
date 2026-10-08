# shellcheck shell=bash
#ddev-generated
#
# ddev-autostart plugin: systemd (Linux)
#
# Plugin contract (every plugin implements these; the entrypoint calls them):
#   plugin_enable  NAME APPROOT
#   plugin_disable NAME APPROOT
#   plugin_status  NAME APPROOT
#   plugin_list_registered        -> one line per registered project:
#                                    NAME<TAB>AUTOSTART<TAB>SERVICE
#       AUTOSTART: enabled | disabled | <init-specific word>
#       SERVICE:   active | inactive | failed | activating | unknown
#
# Design:
#   - A system unit (not --user), so it runs at boot without anyone logging in.
#   - Runs as the invoking user: DDEV refuses to run as root, and the project's
#     Docker context, ~/.ddev config and mkcert CA all belong to that user.
#   - Type=oneshot + RemainAfterExit: `ddev start` returns once containers are up.
#   - Orders after docker.service when it exists, and also polls `docker info`
#     so Docker Desktop for Linux / socket-activated daemons still work.
#   - Rootless Docker and Podman run as a per-user service under /run/user/UID.
#     The unit then orders after user@UID.service, which only starts at boot if
#     the user has lingering enabled; `enable` warns when it's off. Detection
#     covers the standard setup (an endpoint under /run/user/UID); a rootless
#     daemon with a custom XDG_RUNTIME_DIR gets no ordering or warning, but the
#     `docker info` wait still applies.
#   - Only files carrying _SD_MARKER are ever changed or removed, so a
#     ddev-autostart-*.service someone else wrote is left alone.

DDEV_AUTOSTART_UNIT_DIR="${DDEV_AUTOSTART_UNIT_DIR:-/etc/systemd/system}"

_SD_MARKER="# Managed by ddev-autostart."

_sd_unit_name() { printf 'ddev-autostart-%s.service' "$1"; }
_sd_unit_path() { printf '%s/%s' "$DDEV_AUTOSTART_UNIT_DIR" "$(_sd_unit_name "$1")"; }

# True if the unit file was written by this add-on: every version since v0.1.0
# starts with the marker line. Only the first line counts, so a foreign unit that
# merely mentions the marker somewhere else is still treated as foreign.
_sd_is_managed() {
    local first_line=""
    [ -f "$1" ] || return 1
    IFS= read -r first_line <"$1" || true
    case "$first_line" in
        "$_SD_MARKER"*) return 0 ;;
        *) return 1 ;;
    esac
}

_sd_not_ours() {
    echo "⚠️  $1 exists but wasn't created by ddev autostart; leaving it alone." >&2
}

# Run a command as root: directly if we are root, via sudo otherwise.
_sd_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "❌ Error: root privileges required and sudo is not available." >&2
        return 1
    fi
}

# Ask for the sudo password once, up front, with a clear reason.
# With DDEV_AUTOSTART_NONINTERACTIVE set, never prompt: succeed only if sudo
# needs no password. Used when no one may be there to type it (add-on removal
# on older DDEV, scripts, CI), where a hidden password prompt would hang.
_sd_require_root() {
    [ "$(id -u)" -eq 0 ] && return 0
    command -v sudo >/dev/null 2>&1 || {
        echo "❌ Error: root privileges required and sudo is not available." >&2
        return 1
    }
    sudo -n true 2>/dev/null && return 0
    if [ -n "${DDEV_AUTOSTART_NONINTERACTIVE:-}" ]; then
        echo "❌ Error: sudo needs a password, but this is running non-interactively." >&2
        return 1
    fi
    echo "🔐 Administrator rights are needed to manage system services."
    sudo -v || { echo "❌ Error: sudo authentication failed." >&2; return 1; }
}

# How to do by hand what plugin_disable does, for when it can't.
_sd_manual_removal() {
    local unit_name
    unit_name="$(_sd_unit_name "$1")"
    echo "   Remove it manually with:"
    echo "     sudo systemctl disable ${unit_name}"
    echo "     sudo rm $(_sd_unit_path "$1")"
    echo "     sudo systemctl daemon-reload"
}

# systemd treats '%' as a specifier prefix; escape it in literal values.
_sd_escape() { printf '%s' "${1//%/%%}"; }

# Exec lines also expand $VARIABLES, so '$' is written as '$$' there too.
_sd_exec_escape() {
    local s="${1//%/%%}"
    printf '%s' "${s//\$/\$\$}"
}

# A path that can't break the unit file's double quotes. systemd also treats a
# backslash as the start of an escape sequence, so it's refused too.
_sd_quotable() {
    case "$1" in *[\"\\]* | *$'\n'*) return 1 ;; esac
}

# A path that can also go inside the single-quoted `sh -c` script.
_sd_shell_safe() {
    _sd_quotable "$1" || return 1
    case "$1" in *[\'\$\`]*) return 1 ;; esac
}

# The Docker endpoint the CLI uses right now: honours DOCKER_HOST,
# DOCKER_CONTEXT and `docker context use`, e.g. unix:///var/run/docker.sock.
_sd_docker_endpoint() {
    "$1" context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null
}

# Is the user's own service manager started at boot? Rootless Docker and Podman
# run inside it, so without lingering they only start once the user logs in.
_sd_lingering() {
    [ -e "/var/lib/systemd/linger/$1" ] ||
        [ "$(loginctl show-user "$1" -p Linger --value 2>/dev/null)" = "yes" ]
}

_sd_linger_hint() {
    echo "⚠️  Docker runs as your user (rootless Docker or Podman), and it only starts at boot"
    echo "   if lingering is enabled for '$1'. Turn it on with:"
    echo "     sudo loginctl enable-linger $1"
}

# The service's PATH: only the folders of the commands it runs (ddev, and docker
# for the wait-for-Docker step), then the standard system folders.
# Deliberately NOT the user's terminal PATH: that can contain relative entries
# ("." would run programs from the project folder at boot), WSL's /mnt/c
# folders that aren't mounted yet at boot, or folders from a virtualenv or
# version manager that only existed in that terminal.
_sd_service_path() {
    local ddev_bin="$1" docker_bin="$2" path="" dir
    local std="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    for dir in "$(dirname "$ddev_bin")" ${docker_bin:+"$(dirname "$docker_bin")"}; do
        case "$dir" in /*) ;; *) continue ;; esac              # absolute only
        case "$dir" in *:* | *[\"\\]* | *$'\n'*) continue ;; esac  # can't go in PATH
        case ":${path}:${std}:" in *":${dir}:"*) continue ;; esac  # already there
        path="${path:+${path}:}${dir}"
    done
    printf '%s' "${path:+${path}:}${std}"
}

# Absolute path of a command as found in PATH, symlinks kept as they are:
# package managers point a stable path (/usr/bin/ddev, …/linuxbrew/bin/ddev) at
# a versioned one (…/Cellar/ddev/1.25.4/bin/ddev) that the next upgrade deletes.
_sd_find_command() {
    local bin
    bin="$(command -v "$1" 2>/dev/null)" || return 1
    case "$bin" in
        /*) ;;
        */*) bin="$(cd "$(dirname "$bin")" && pwd)/$(basename "$bin")" ;;
        *) return 1 ;;   # a shell function or alias, not a file
    esac
    printf '%s\n' "$bin"
}

# Arguments: NAME ROOT USER GROUP HOME DDEV_BIN DOCKER_BIN USER_RUNTIME_DIR
# USER_RUNTIME_DIR is /run/user/UID when Docker listens there (rootless), else "".
# DOCKER_HOST, DOCKER_CONTEXT and DOCKER_CONFIG are copied from the environment
# when set, so a runtime chosen that way is also used at boot. DOCKER_CONFIG
# matters even without the other two: it's where `docker context use` stores the
# chosen context (default ~/.docker, found through HOME).
_sd_render_unit() {
    local name="$1" root="$2" user="$3" group="$4" home="$5" ddev_bin="$6" docker_bin="$7"
    local runtime_dir="${8:-}" docker_deps="" extra_env="" exec_ddev exec_docker var
    exec_ddev="$(_sd_exec_escape "$ddev_bin")"
    exec_docker="$(_sd_exec_escape "$docker_bin")"
    if systemctl list-unit-files docker.service >/dev/null 2>&1 &&
        systemctl list-unit-files docker.service 2>/dev/null | grep -q '^docker\.service'; then
        docker_deps=$'Wants=docker.service\nAfter=docker.service'
    fi
    if [ -n "$runtime_dir" ]; then
        # Not Wants=: starting the user's manager is lingering's job, not ours.
        docker_deps="${docker_deps:+${docker_deps}$'\n'}After=user@${runtime_dir##*/}.service"
        extra_env="Environment=\"XDG_RUNTIME_DIR=$(_sd_escape "$runtime_dir")\""
    fi
    for var in DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG; do
        # plugin_enable has already refused values _sd_quotable rejects.
        if [ -n "${!var:-}" ] && _sd_quotable "${!var}"; then
            extra_env="${extra_env:+${extra_env}$'\n'}Environment=\"${var}=$(_sd_escape "${!var}")\""
        fi
    done

    cat <<EOF
# Managed by ddev-autostart. Do not edit; run \`ddev autostart disable ${name}\` instead.
[Unit]
Description=DDEV autostart: ${name}
Wants=network-online.target
After=network-online.target
${docker_deps}

[Service]
Type=oneshot
RemainAfterExit=yes
User=${user}
Group=${group}
WorkingDirectory=$(_sd_escape "$root")
Environment="HOME=$(_sd_escape "$home")"
Environment="PATH=$(_sd_escape "$(_sd_service_path "$ddev_bin" "$docker_bin")")"
${extra_env}
# Wait up to ~2 minutes for the Docker daemon to answer before starting.
# (\$\$ is systemd's escape for a literal \$ inside Exec lines.)
ExecStartPre=/bin/sh -c 'i=0; until "${exec_docker}" info >/dev/null 2>&1; do i=\$\$((i+1)); [ \$\$i -ge 60 ] && exit 1; sleep 2; done'
ExecStart="${exec_ddev}" start ${name}
ExecStop="${exec_ddev}" stop ${name}
TimeoutStartSec=600
TimeoutStopSec=180

[Install]
WantedBy=multi-user.target
EOF
}

plugin_enable() {
    local name="$1" root="$2"
    local unit unit_name user group home ddev_bin docker_bin tmp endpoint runtime_dir=""

    if [ "$(id -u)" -eq 0 ]; then
        echo "❌ Error: run this as your normal user, not root (DDEV does not run as root)." >&2
        return 1
    fi
    if ! _sd_quotable "$root"; then
        echo "❌ Error: the project path contains a quote, backslash or newline, which a systemd unit can't hold safely: ${root}" >&2
        return 1
    fi
    if ! _sd_quotable "$HOME"; then
        echo "❌ Error: your home folder's path contains a quote, backslash or newline: ${HOME}" >&2
        return 1
    fi
    # These select which Docker the CLI talks to, and are copied into the unit.
    # Refuse rather than drop a value the unit can't hold: dropping it would make
    # the boot service use a different Docker than this terminal.
    local var
    for var in DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG; do
        if [ -n "${!var:-}" ] && ! _sd_quotable "${!var}"; then
            echo "❌ Error: ${var} contains a quote, backslash or newline, which a systemd unit can't hold safely: ${!var}" >&2
            return 1
        fi
    done

    if ! ddev_bin="$(_sd_find_command ddev)"; then
        echo "❌ Error: ddev not found in PATH." >&2
        return 1
    fi
    if ! _sd_quotable "$ddev_bin"; then
        echo "❌ Error: ddev's path contains a quote, backslash or newline: ${ddev_bin}" >&2
        return 1
    fi
    # The boot service runs `docker info` to wait for Docker. Without the docker
    # command it would wait two minutes and fail at every boot, so refuse.
    if ! docker_bin="$(_sd_find_command docker)"; then
        echo "❌ Error: the docker command isn't in your PATH, so the boot service couldn't tell when Docker is ready." >&2
        return 1
    fi
    if ! _sd_shell_safe "$docker_bin"; then
        echo "❌ Error: docker's path contains a character a systemd unit can't hold safely: ${docker_bin}" >&2
        return 1
    fi

    user="$(id -un)"
    group="$(id -gn)"
    home="$HOME"
    unit="$(_sd_unit_path "$name")"
    unit_name="$(_sd_unit_name "$name")"

    if [ -e "$unit" ] && ! _sd_is_managed "$unit"; then
        _sd_not_ours "$unit"
        return 1
    fi

    # Test whether Docker actually works, rather than guessing from the docker
    # group: rootless Docker, Podman and Docker Desktop don't use that group.
    if ! timeout 20 "$docker_bin" info >/dev/null 2>&1; then
        echo "⚠️  Warning: Docker isn't responding right now. The service will still wait for it at boot."
    fi
    endpoint="$(_sd_docker_endpoint "$docker_bin")"
    case "$endpoint" in
        "unix:///run/user/$(id -u)/"*)
            runtime_dir="/run/user/$(id -u)"
            _sd_lingering "$user" || _sd_linger_hint "$user"
            ;;
    esac

    tmp="$(mktemp)"
    _sd_render_unit "$name" "$root" "$user" "$group" "$home" "$ddev_bin" "$docker_bin" "$runtime_dir" >"$tmp"

    if [ -f "$unit" ] && cmp -s "$tmp" "$unit"; then
        rm -f "$tmp"
        if [ "$(systemctl is-enabled "$unit_name" 2>/dev/null)" = "enabled" ]; then
            echo "✅ ${name} is already configured to start on boot (${unit})."
            return 0
        fi
        # The unit is right, but someone disabled it: turn it back on, and say so
        # if that fails rather than claiming it's configured.
        if ! { _sd_require_root && _sd_root systemctl enable "$unit_name"; }; then
            echo "❌ Error: ${unit} is installed but couldn't be enabled." >&2
            return 1
        fi
        echo "✅ ${name} was installed but disabled; it's enabled again and will start on boot."
        return 0
    fi

    echo "Configuring systemd service for ${name}..."
    if ! { _sd_require_root &&
        _sd_root install -D -m 0644 -o root -g root "$tmp" "$unit" &&
        _sd_root systemctl daemon-reload &&
        _sd_root systemctl enable "$unit_name"; }; then
        rm -f "$tmp"
        echo "❌ Error: failed to install the systemd unit." >&2
        return 1
    fi
    rm -f "$tmp"

    echo "✅ ${name} will start automatically on boot."
    echo "   Unit: ${unit}"
    echo "   Test it now with: sudo systemctl start ${unit_name}"
}

plugin_disable() {
    local name="$1"
    local unit unit_name
    unit="$(_sd_unit_path "$name")"
    unit_name="$(_sd_unit_name "$name")"

    if [ ! -f "$unit" ]; then
        echo "ℹ️  ${name} is not registered for autostart; nothing to do."
        return 0
    fi
    if ! _sd_is_managed "$unit"; then
        _sd_not_ours "$unit"
        return 1
    fi

    echo "Removing systemd service for ${name}..."
    if ! _sd_require_root; then
        _sd_manual_removal "$name" >&2
        return 1
    fi
    # Deliberately no --now: stopping the unit would run `ddev stop` on a
    # project the user may be actively working in.
    _sd_root systemctl disable "$unit_name" >/dev/null 2>&1 || true
    if ! _sd_root rm -f "$unit"; then
        echo "❌ Error: could not remove ${unit}." >&2
        _sd_manual_removal "$name" >&2
        return 1
    fi
    _sd_root systemctl daemon-reload || true
    _sd_root systemctl reset-failed "$unit_name" >/dev/null 2>&1 || true

    echo "✅ ${name} will no longer start on boot. (The project itself was left running.)"
}

plugin_status() {
    local name="$1" root="$2"
    local unit unit_name enabled active result
    unit="$(_sd_unit_path "$name")"
    unit_name="$(_sd_unit_name "$name")"

    echo "Project:   ${name}"
    echo "Approot:   ${root:-<unknown>}"
    echo "Init:      systemd"
    echo "Unit:      ${unit}"

    if [ ! -f "$unit" ]; then
        echo "Autostart: ❌ disabled (no unit installed)"
        return 0
    fi
    if ! _sd_is_managed "$unit"; then
        echo "Autostart: ⚠️  a unit with this name exists but wasn't created by ddev autostart"
        return 0
    fi

    enabled="$(systemctl is-enabled "$unit_name" 2>/dev/null || true)"
    active="$(systemctl is-active "$unit_name" 2>/dev/null || true)"
    result="$(systemctl show -p Result --value "$unit_name" 2>/dev/null || true)"

    if [ "$enabled" = "enabled" ]; then
        echo "Autostart: ✅ enabled"
    else
        echo "Autostart: ⚠️  unit installed but '${enabled:-unknown}'"
    fi
    echo "Service:   ${active:-unknown}${result:+ (last result: ${result})}"

    if [ "$active" = "failed" ] || { [ -n "$result" ] && [ "$result" != "success" ]; }; then
        echo "Logs:      journalctl -u ${unit_name} -b"
    fi
    if grep -q '^Environment="XDG_RUNTIME_DIR=' "$unit" && ! _sd_lingering "$(id -un)"; then
        _sd_linger_hint "$(id -un)"
    fi
}

plugin_list_registered() {
    local f base name enabled active
    for f in "$DDEV_AUTOSTART_UNIT_DIR"/ddev-autostart-*.service; do
        [ -f "$f" ] || continue
        base="${f##*/}"
        name="${base#ddev-autostart-}"
        name="${name%.service}"
        ddev_autostart_valid_name "$name" || continue
        _sd_is_managed "$f" || continue
        enabled="$(systemctl is-enabled "$base" 2>/dev/null || true)"
        active="$(systemctl is-active "$base" 2>/dev/null || true)"
        printf '%s\t%s\t%s\n' "$name" "${enabled:-unknown}" "${active:-unknown}"
    done
}
