# shellcheck shell=bash
#ddev-generated
#
# ddev-autostart: `ddev autostart list`
# Merges every project DDEV knows about with every project the active plugin
# has registered, so it also catches "orphans": boot services whose project
# was deleted or renamed and will now fail on every boot.
#
# Needs: ddev_autostart_list_projects (lib/resolve-approot.sh)
#        plugin_list_registered       (the active plugin)
# Portable to macOS: bash 3.2 (no associative arrays) and BSD awk.

ddev_autostart_print_list() {
    local projects registered rows

    projects="$(mktemp)"
    registered="$(mktemp)"
    ddev_autostart_list_projects >"$projects" 2>/dev/null || true
    plugin_list_registered >"$registered" 2>/dev/null || true

    # Row: PROJECT  AUTOSTART  SERVICE  DDEV  APPROOT
    rows="$(awk -F'\t' -v OFS='\t' '
        FILENAME == ARGV[1] {             # registered: name, autostart, service
            if ($1 == "") next
            reg_auto[$1] = $2; reg_svc[$1] = $3
            next
        }
        {                                 # projects: name, approot, ddev status
            if ($1 == "" || ($1 in seen)) next
            seen[$1] = 1
            if ($1 in reg_auto) { auto = reg_auto[$1]; svc = reg_svc[$1] }
            else                { auto = "disabled";   svc = "-" }
            print $1, auto, svc, ($3 == "" ? "-" : $3), ($2 == "" ? "-" : $2)
        }
        END {
            for (n in reg_auto)
                if (!(n in seen)) print n, "orphaned", reg_svc[n], "-", "(project not found)"
        }
    ' "$registered" "$projects" | LC_ALL=C sort -t"$(printf '\t')" -k1,1)"

    rm -f "$projects" "$registered"

    if [ -z "$rows" ]; then
        echo "No DDEV projects found."
        return 0
    fi

    printf '%s\n' "$rows" | awk -F'\t' '
        BEGIN {
            h[1] = "PROJECT"; h[2] = "AUTOSTART"; h[3] = "SERVICE"; h[4] = "DDEV"; h[5] = "APPROOT"
            for (i = 1; i <= 5; i++) w[i] = length(h[i])
        }
        {
            n++
            for (i = 1; i <= 5; i++) { cell[n, i] = $i; if (length($i) > w[i]) w[i] = length($i) }
            if ($2 == "orphaned") orphans = orphans " " $1
            if ($3 == "failed")   failed  = failed  " " $1
        }
        END {
            fmt = "%-" w[1] "s  %-" w[2] "s  %-" w[3] "s  %-" w[4] "s  %s\n"
            printf fmt, h[1], h[2], h[3], h[4], h[5]
            for (r = 1; r <= n; r++) printf fmt, cell[r, 1], cell[r, 2], cell[r, 3], cell[r, 4], cell[r, 5]
            if (orphans != "") {
                print ""
                print "⚠️  Orphaned services (project no longer exists):" orphans
                print "   Remove with: ddev autostart disable <project>"
            }
            if (failed != "") {
                print ""
                print "❌ Failed to start:" failed
                print "   Details with: ddev autostart status <project>"
            }
        }
    '
}
