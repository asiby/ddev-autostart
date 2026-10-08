# shellcheck shell=bash
#ddev-generated
#
# ddev-autostart: project path resolution helpers.
# Sourced by the main `autostart` command. Defines functions only; no side effects.
#
# Resolution order for a project's approot when we're not inside the project:
#   1. `ddev list --json-output`  (authoritative; parsed with jq, else python3)
#   2. DDEV's project registry file, project_list.yaml (works even when Docker is down)
# Every candidate is validated before it is trusted.

# Project names end up in systemd/launchd unit names and file paths, so keep them boring.
ddev_autostart_valid_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# DDEV's global config dir: ~/.ddev by default, $XDG_CONFIG_HOME/ddev on some setups.
# Prints every candidate that exists, preferred first.
ddev_autostart_global_dirs() {
    local d
    for d in "${HOME}/.ddev" "${XDG_CONFIG_HOME:-${HOME}/.config}/ddev"; do
        [ -d "$d" ] && printf '%s\n' "$d"
    done
    return 0
}

# A trustworthy approot is absolute, single-line, exists, and contains a DDEV config.
ddev_autostart_validate_root() {
    local root="${1:-}"
    case "$root" in
        /*) ;;
        *) return 1 ;;
    esac
    case "$root" in *$'\n'*) return 1 ;; esac
    [ -d "$root" ] && [ -f "${root}/.ddev/config.yaml" ]
}

# --- Strategy 1: ddev list --json-output -------------------------------------
# Output is one logrus JSON object per line; the project array lives in .raw.
_ddev_autostart_root_from_cli() {
    local name="$1" out=""
    command -v ddev >/dev/null 2>&1 || return 1
    out="$(ddev list --json-output 2>/dev/null)" || return 1
    [ -n "$out" ] || return 1

    if command -v jq >/dev/null 2>&1; then
        printf '%s\n' "$out" | jq -rR --arg n "$name" '
            fromjson? | .raw? | arrays | .[]
            | select(type == "object" and .name == $n) | .approot // empty
        ' 2>/dev/null | awk 'NF { print; exit }'
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        printf '%s\n' "$out" | python3 -c '
import json, sys
name = sys.argv[1]
for line in sys.stdin:
    try:
        doc = json.loads(line)
    except ValueError:
        continue
    raw = doc.get("raw") if isinstance(doc, dict) else None
    if isinstance(raw, list):
        for p in raw:
            if isinstance(p, dict) and p.get("name") == name and p.get("approot"):
                print(p["approot"])
                sys.exit(0)
' "$name" 2>/dev/null || true
        return 0
    fi

    return 1
}

# --- Strategy 2: project_list.yaml --------------------------------------------
# DDEV >= 1.22 keeps registered projects here (older releases used global_config.yaml):
#   my-site:
#       approot: /home/me/code/my-site
#       used_host_ports: []
_ddev_autostart_root_from_registry() {
    local name="$1" dir file
    while IFS= read -r dir; do
        file="${dir}/project_list.yaml"
        [ -f "$file" ] || continue
        awk -v n="$name" -v q="'" '
            function unquote(s) {
                sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
                if (length(s) >= 2 && (s ~ /^".*"$/ || (substr(s, 1, 1) == q && substr(s, length(s), 1) == q))) s = substr(s, 2, length(s) - 2)
                return s
            }
            /^[^ \t#][^:]*:[ \t]*$/ {
                key = $0; sub(/:[ \t]*$/, "", key)
                in_project = (unquote(key) == n)
                next
            }
            in_project && /^[ \t]+approot:/ {
                val = $0; sub(/^[ \t]+approot:/, "", val)
                print unquote(val)
                exit
            }
        ' "$file"
        return 0
    done < <(ddev_autostart_global_dirs)
    return 1
}

# Public entry point. Prints the absolute approot on success, returns 1 otherwise.
ddev_autostart_resolve_approot() {
    local name="${1:-}" candidate=""
    ddev_autostart_valid_name "$name" || return 1

    if [ -n "${DDEV_AUTOSTART_PROJECTS_LOADED:-}" ]; then
        # Cache loaded by ddev_autostart_load_projects: no extra `ddev list` call.
        candidate="$(printf '%s\n' "$DDEV_AUTOSTART_PROJECTS" |
            awk -F'\t' -v n="$name" '$1 == n { print $2; exit }')"
    else
        candidate="$(_ddev_autostart_root_from_cli "$name" || true)"
    fi
    if ddev_autostart_validate_root "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
    fi

    candidate="$(_ddev_autostart_root_from_registry "$name" || true)"
    if ddev_autostart_validate_root "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
    fi

    return 1
}

# --- Listing all projects -----------------------------------------------------
# Prints one line per known project: NAME<TAB>APPROOT<TAB>DDEV_STATUS
# DDEV_STATUS is "-" when it can't be known (registry fallback, Docker down).
ddev_autostart_list_projects() {
    local out="" rows="" dir file

    if command -v ddev >/dev/null 2>&1; then
        out="$(ddev list --json-output 2>/dev/null || true)"
    fi

    if [ -n "$out" ]; then
        if command -v jq >/dev/null 2>&1; then
            rows="$(printf '%s\n' "$out" | jq -rR '
                fromjson? | .raw? | arrays | .[]
                | select(type == "object" and (.name // "") != "")
                | [.name, (.approot // ""), ((.status // "") | if . == "" then "-" else . end)]
                | @tsv
            ' 2>/dev/null || true)"
        elif command -v python3 >/dev/null 2>&1; then
            rows="$(printf '%s\n' "$out" | python3 -c '
import json, sys
for line in sys.stdin:
    try:
        doc = json.loads(line)
    except ValueError:
        continue
    raw = doc.get("raw") if isinstance(doc, dict) else None
    if isinstance(raw, list):
        for p in raw:
            if isinstance(p, dict) and p.get("name"):
                print("\t".join([p["name"], p.get("approot") or "", p.get("status") or "-"]))
' 2>/dev/null || true)"
        fi
    fi

    if [ -n "$rows" ]; then
        printf '%s\n' "$rows"
        return 0
    fi

    # Fallback: read every project from the registry file.
    while IFS= read -r dir; do
        file="${dir}/project_list.yaml"
        [ -f "$file" ] || continue
        awk -v q="'" '
            function unquote(s) {
                sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
                if (length(s) >= 2 && (s ~ /^".*"$/ || (substr(s, 1, 1) == q && substr(s, length(s), 1) == q))) s = substr(s, 2, length(s) - 2)
                return s
            }
            /^[^ \t#][^:]*:[ \t]*$/ {
                if (name != "") print name "\t" root "\t-"
                name = $0; sub(/:[ \t]*$/, "", name); name = unquote(name); root = ""
                next
            }
            name != "" && /^[ \t]+approot:/ {
                root = $0; sub(/^[ \t]+approot:/, "", root); root = unquote(root)
            }
            END { if (name != "") print name "\t" root "\t-" }
        ' "$file"
        return 0
    done < <(ddev_autostart_global_dirs)
    return 0
}

# --- Cache ------------------------------------------------------------------------
# `ddev list` is the slow part of every lookup and gets slower with more running
# projects. Call this once in the main shell (NOT inside $(...), where the
# variables would be lost) and every later ddev_autostart_resolve_approot reads
# the cached rows instead of running `ddev list` again.
# Sets DDEV_AUTOSTART_PROJECTS: the rows of ddev_autostart_list_projects.
ddev_autostart_load_projects() {
    [ -n "${DDEV_AUTOSTART_PROJECTS_LOADED:-}" ] && return 0
    DDEV_AUTOSTART_PROJECTS="$(ddev_autostart_list_projects || true)"
    DDEV_AUTOSTART_PROJECTS_LOADED=1
}

# --- Where the add-on itself is recorded ----------------------------------------
# DDEV keeps an add-on's install record in the project it was installed from, at
# <approot>/.ddev/addon-metadata/<name>/manifest.yaml. Updating or removing the
# add-on should happen from that project. Must match `name:` in install.yaml.
DDEV_AUTOSTART_ADDON_NAME="ddev.d"

# Prints the name of each project holding the add-on's install record.
# Call ddev_autostart_load_projects first (in the main shell).
ddev_autostart_install_records() {
    local name root
    printf '%s\n' "${DDEV_AUTOSTART_PROJECTS:-}" |
        while IFS="$(printf '\t')" read -r name root _; do
            if [ -z "$name" ] || [ -z "$root" ]; then continue; fi
            [ -f "${root}/.ddev/addon-metadata/${DDEV_AUTOSTART_ADDON_NAME}/manifest.yaml" ] &&
                printf '%s\n' "$name"
        done
    return 0
}

# Footer for `status` and `list`: which project to update or remove the add-on from.
ddev_autostart_print_install_footer() {
    local records count
    ddev_autostart_load_projects
    records="$(ddev_autostart_install_records)"
    count="$(printf '%s' "$records" | grep -c . || true)"
    echo
    case "$count" in
        0)
            echo "ℹ️  Couldn't find which project the add-on was installed from (that project may have been deleted)."
            echo "   Running \`ddev add-on get asiby/ddev.d\` in any project updates it and records it there."
            ;;
        1)
            echo "ℹ️  The add-on was installed from project '${records}'. Update or remove it from there."
            ;;
        *)
            echo "⚠️  The add-on is recorded in more than one project: $(printf '%s' "$records" | paste -sd, - | sed 's/,/, /g')."
            echo "   That happens when it's updated from a different project. Update it from one of them, and"
            echo "   when uninstalling, run \`ddev add-on remove ${DDEV_AUTOSTART_ADDON_NAME}\` in each."
            ;;
    esac
}

# Prints one line, NEWEST<TAB>VERSION<TAB>REPOSITORY<TAB>INSTALL_DATE<TAB>PROJECT,
# from the most recent install record (the one whose files are in place when
# the add-on is recorded in several projects). VERSION is the release tag DDEV
# installed, or "-" for an install from a local folder (empty fields are "-"). Prints nothing if no
# record is found. Call ddev_autostart_load_projects first.
ddev_autostart_install_info() {
    local name root manifest
    ddev_autostart_install_records |
        while IFS= read -r name; do
            root="$(printf '%s\n' "${DDEV_AUTOSTART_PROJECTS:-}" |
                awk -F'\t' -v n="$name" '$1 == n { print $2; exit }')"
            manifest="${root}/.ddev/addon-metadata/${DDEV_AUTOSTART_ADDON_NAME}/manifest.yaml"
            awk -v project="$name" -v q="'" '
                function unquote(s) {
                    sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
                    if (length(s) >= 2 && (s ~ /^".*"$/ || (substr(s, 1, 1) == q && substr(s, length(s), 1) == q))) s = substr(s, 2, length(s) - 2)
                    return s
                }
                /^version:/      { v = $0; sub(/^version:/, "", v); v = unquote(v) }
                /^repository:/   { r = $0; sub(/^repository:/, "", r); r = unquote(r) }
                /^install_date:/ { d = $0; sub(/^install_date:/, "", d); d = unquote(d) }
                # "-" for empty fields: `read` with a tab IFS merges empty fields.
                function f(x) { return (x == "" ? "-" : x) }
                END { printf "%s\t%s\t%s\t%s\t%s\n", f(d), f(v), f(r), f(d), project }
            ' "$manifest"
        done | LC_ALL=C sort -r | head -n 1
}

# `ddev autostart --version`: what's installed, plus what a bug report needs.
ddev_autostart_print_version() {
    local plugin="$1" info version repo date project ddev_version
    ddev_autostart_load_projects
    info="$(ddev_autostart_install_info)"
    IFS="$(printf '\t')" read -r _ version repo date project <<<"$info" || true
    date="${date%%T*}"
    if [ -z "$info" ]; then
        echo "ddev autostart (version unknown: couldn't find the add-on's install record)"
    elif [ "$version" != "-" ]; then
        echo "ddev autostart ${version} (${repo}, installed ${date} from project '${project}')"
    else
        echo "ddev autostart (development copy from ${repo}, installed ${date} from project '${project}')"
    fi
    ddev_version="$(ddev --version 2>/dev/null | awk '{ print $NF; exit }')"
    echo "Plugin:  ${plugin}"
    echo "DDEV:    ${ddev_version:-unknown}"
}
