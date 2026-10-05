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

DDEV_AUTOSTART_UNIT_DIR="${DDEV_AUTOSTART_UNIT_DIR:-/etc/systemd/system}"

_sd_unit_name() { printf 'ddev-autostart-%s.service' "$1"; }
_sd_unit_path() { printf '%s/%s' "$DDEV_AUTOSTART_UNIT_DIR" "$(_sd_unit_name "$1")"; }

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

_sd_render_unit() {
    local name="$1" root="$2" user="$3" group="$4" home="$5" ddev_bin="$6"
    local docker_deps=""
    if systemctl list-unit-files docker.service >/dev/null 2>&1 &&
        systemctl list-unit-files docker.service 2>/dev/null | grep -q '^docker\.service'; then
        docker_deps=$'Wants=docker.service\nAfter=docker.service'
    fi

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
Environment="PATH=$(_sd_escape "$(dirname "$ddev_bin")"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# Wait up to ~2 minutes for the Docker daemon to answer before starting.
# (\$\$ is systemd's escape for a literal \$ inside Exec lines.)
ExecStartPre=/bin/sh -c 'i=0; until docker info >/dev/null 2>&1; do i=\$\$((i+1)); [ \$\$i -ge 60 ] && exit 1; sleep 2; done'
ExecStart=${ddev_bin} start ${name}
ExecStop=${ddev_bin} stop ${name}
TimeoutStartSec=600
TimeoutStopSec=180

[Install]
WantedBy=multi-user.target
EOF
}

plugin_enable() {
    local name="$1" root="$2"
    local unit user group home ddev_bin tmp

    if [ "$(id -u)" -eq 0 ]; then
        echo "❌ Error: run this as your normal user, not root (DDEV does not run as root)." >&2
        return 1
    fi
    case "$root" in *$'\n'*)
        echo "❌ Error: project path contains a newline; refusing to write a unit." >&2
        return 1 ;;
    esac

    ddev_bin="$(command -v ddev || true)"
    if [ -z "$ddev_bin" ]; then
        echo "❌ Error: ddev not found in PATH." >&2
        return 1
    fi
    # Keep the path as found in PATH; do NOT resolve symlinks. Package managers
    # point a stable path (/usr/bin/ddev, …/linuxbrew/bin/ddev) at a versioned
    # one (…/Cellar/ddev/1.25.4/bin/ddev) that the next upgrade deletes.
    case "$ddev_bin" in
        /*) ;;
        *) ddev_bin="$(cd "$(dirname "$ddev_bin")" && pwd)/$(basename "$ddev_bin")" ;;
    esac

    user="$(id -un)"
    group="$(id -gn)"
    home="$HOME"
    unit="$(_sd_unit_path "$name")"

    if ! id -nG "$user" | tr ' ' '\n' | grep -qx docker; then
        echo "⚠️  Warning: '$user' is not in the 'docker' group; the service may fail at boot."
    fi

    tmp="$(mktemp)"
    _sd_render_unit "$name" "$root" "$user" "$group" "$home" "$ddev_bin" >"$tmp"

    if [ -f "$unit" ] && cmp -s "$tmp" "$unit"; then
        rm -f "$tmp"
        echo "✅ ${name} is already configured to start on boot (${unit})."
        _sd_root systemctl enable "$(_sd_unit_name "$name")" >/dev/null 2>&1 || true
        return 0
    fi

    echo "Configuring systemd service for ${name}..."
    if ! { _sd_require_root &&
        _sd_root install -D -m 0644 -o root -g root "$tmp" "$unit" &&
        _sd_root systemctl daemon-reload &&
        _sd_root systemctl enable "$(_sd_unit_name "$name")"; }; then
        rm -f "$tmp"
        echo "❌ Error: failed to install the systemd unit." >&2
        return 1
    fi
    rm -f "$tmp"

    echo "✅ ${name} will start automatically on boot."
    echo "   Unit: ${unit}"
    echo "   Test it now with: sudo systemctl start $(_sd_unit_name "$name")"
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
}

plugin_list_registered() {
    local f base name enabled active
    for f in "$DDEV_AUTOSTART_UNIT_DIR"/ddev-autostart-*.service; do
        [ -f "$f" ] || continue
        base="${f##*/}"
        name="${base#ddev-autostart-}"
        name="${name%.service}"
        ddev_autostart_valid_name "$name" || continue
        enabled="$(systemctl is-enabled "$base" 2>/dev/null || true)"
        active="$(systemctl is-active "$base" 2>/dev/null || true)"
        printf '%s\t%s\t%s\n' "$name" "${enabled:-unknown}" "${active:-unknown}"
    done
}
