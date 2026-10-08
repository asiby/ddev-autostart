# shellcheck shell=bash
#ddev-generated
#
# ddev-autostart: which plugin handles this system.
# Shared by the `autostart` command and its shell completion script, so both
# always pick the same plugin. Defines functions only; no side effects.

# Prints the plugin name for this system (systemd, openrc, launchd, windows),
# or "unknown". DDEV_AUTOSTART_PLUGIN overrides it, for testing and edge cases.
ddev_autostart_detect_plugin() {
    local os_type="unknown"
    case "${OSTYPE:-}" in
        linux*)
            if [ -d /run/systemd/system ]; then
                os_type="systemd" # systemd is actually PID 1, not merely installed
            elif command -v rc-service >/dev/null 2>&1; then
                os_type="openrc"
            fi
            ;;
        darwin*) os_type="launchd" ;;
        msys* | cygwin*) os_type="windows" ;;
    esac
    printf '%s\n' "${DDEV_AUTOSTART_PLUGIN:-$os_type}"
}

# Path of the plugin file for PLUGIN in SUPPORT_DIR; fails if there isn't one.
ddev_autostart_plugin_path() {
    local support_dir="$1" plugin="$2"
    [ "$plugin" != "unknown" ] && [ -f "${support_dir}/plugins/${plugin}.sh" ] &&
        printf '%s\n' "${support_dir}/plugins/${plugin}.sh"
}
