#!/usr/bin/env bats

# Bats is a testing framework for Bash
# Documentation https://bats-core.readthedocs.io/en/stable/
# Bats libraries documentation https://github.com/ztombol/bats-docs

# For local tests, install bats-core, bats-assert, bats-file, bats-support
# And run this in the add-on root directory:
#   bats ./tests/test.bats
# To exclude release tests:
#   bats ./tests/test.bats --filter-tags '!release'
# For debugging:
#   bats ./tests/test.bats --show-output-of-passing-tests --verbose-run --print-output-on-failure
#
# The systemd tests register a REAL boot service on the machine running them
# (and remove it in teardown). They run only when systemd is PID 1 and sudo
# needs no password, as on GitHub's Ubuntu runners; elsewhere they are skipped.

setup() {
  set -eu -o pipefail

  export GITHUB_REPO=asiby/ddev-autostart
  export ADDON_NAME=ddev-autostart

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-$(basename "${GITHUB_REPO}" | tr '.' '-')"
  export UNIT="ddev-autostart-${PROJNAME}.service"
  mkdir -p "${HOME}/tmp"
  export TESTDIR="$(mktemp -d "${HOME}/tmp/${PROJNAME}.XXXXXX")"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site
  assert_success
  run ddev start -y
  assert_success
}

can_test_systemd() {
  [ -d /run/systemd/system ] && sudo -n true 2>/dev/null
}

project_status() {
  ddev describe "${PROJNAME}" -j 2>/dev/null | jq -r '.raw.status // empty'
}

health_checks() {
  # Usage is shown with no arguments.
  run ddev autostart
  assert_success
  assert_output --partial "Usage: ddev autostart"

  # list works and shows the project as not registered.
  run ddev autostart list
  assert_success
  assert_output --regexp "${PROJNAME}[[:space:]]+disabled"

  # Outside any project: the name is required, and the path is resolved from it.
  cd "${HOME}"
  run ddev autostart status
  assert_failure
  assert_output --partial "No DDEV project detected"
  run ddev autostart status "${PROJNAME}"
  assert_success
  assert_output --partial "Approot:   ${TESTDIR}"
  run ddev autostart enable no-such-project
  assert_failure
  assert_output --partial "Could not find project(s): no-such-project"

  # A typo anywhere in a list of names changes nothing.
  run ddev autostart enable "${PROJNAME}" no-such-project
  assert_failure
  assert_output --partial "Nothing was changed"

  # enable --all is refused on purpose; --running is the alternative.
  run ddev autostart enable --all
  assert_failure
  assert_output --partial "enable --running"
  cd "${TESTDIR}"

  if ! can_test_systemd; then
    echo "# skipping systemd checks: needs systemd as PID 1 and passwordless sudo" >&3
    return 0
  fi

  # Make docker reachable from an unusual folder too, like a Homebrew or Nix
  # install. The service must add that folder (and only that) to its PATH.
  DOCKERBIN="$(mktemp -d "${HOME}/tmp/dockerbin.XXXXXX")"
  ln -s "$(command -v docker)" "${DOCKERBIN}/docker"

  # Inside the project: name auto-detected, real unit installed and enabled.
  run env PATH="${DOCKERBIN}:${PATH}" ddev autostart enable
  assert_success
  assert_file_exists "/etc/systemd/system/${UNIT}"
  run systemctl is-enabled "${UNIT}"
  assert_output "enabled"
  run grep '^Environment="PATH=' "/etc/systemd/system/${UNIT}"
  assert_output --partial "${DOCKERBIN}:"
  refute_output --regexp '(^|[=:])\.?(:|"$)'   # no relative or empty entries
  run systemd-analyze verify "/etc/systemd/system/${UNIT}"
  assert_success

  # Enabling again is a no-op.
  run env PATH="${DOCKERBIN}:${PATH}" ddev autostart enable
  assert_success
  assert_output --partial "already configured"

  # Simulate boot: stop the project, then start it only through the service.
  run ddev stop "${PROJNAME}"
  assert_success
  run sudo systemctl start "${UNIT}"
  if [ "$status" -ne 0 ]; then
    sudo journalctl -u "${UNIT}" --no-pager -n 50 >&3 || true
  fi
  assert_success
  run project_status
  assert_output "running"

  run ddev autostart list
  assert_success
  assert_output --regexp "${PROJNAME}[[:space:]]+enabled[[:space:]]+active[[:space:]]+running"

  # Disable removes the unit but leaves the project running.
  run ddev autostart disable
  assert_success
  assert_file_not_exists "/etc/systemd/system/${UNIT}"
  run project_status
  assert_output "running"

  # --running registers the running test project (from anywhere).
  cd "${HOME}"
  run ddev autostart enable --running
  assert_success
  assert_output --partial "${PROJNAME}"
  assert_file_exists "/etc/systemd/system/${UNIT}"

  # Several names at once, by name from outside the project.
  run ddev autostart status "${PROJNAME}" "${PROJNAME}"
  assert_success
  run ddev autostart disable --all
  assert_success
  assert_file_not_exists "/etc/systemd/system/${UNIT}"
  cd "${TESTDIR}"

  # --all with nothing registered is a friendly no-op.
  run ddev autostart disable --all
  assert_success
  assert_output --partial "No projects are registered"
}

# Checks for behaviour added after the latest release. Only run against the
# code in this checkout, so "install from release" keeps testing what users
# actually have until the next release is published.
unreleased_checks() {
  local unit_file="/etc/systemd/system/${UNIT}"

  # status and list name the project the add-on was installed from (this one),
  # from inside the project and from anywhere else.
  cd "${TESTDIR}"
  run ddev autostart status
  assert_success
  assert_output --partial "installed from project '${PROJNAME}'"
  cd "${HOME}"
  run ddev autostart list
  assert_success
  assert_output --partial "installed from project '${PROJNAME}'"

  # --version reports this checkout as a development copy, plus plugin and DDEV.
  run ddev autostart --version
  assert_success
  assert_output --partial "development copy from ${DIR}"
  assert_output --partial "from project '${PROJNAME}'"
  assert_output --regexp "Plugin: +[a-z]"
  assert_output --regexp "DDEV: +v[0-9]"

  # Tab completion (what Tab runs): actions, options and project names.
  run ddev __complete autostart ""
  assert_output --partial "enable"
  assert_output --partial "--version"
  run ddev __complete autostart enable ""
  assert_output --partial "--running"
  assert_output --partial "${PROJNAME}"
  run ddev __complete autostart status ""
  assert_output --partial "${PROJNAME}"
  run ddev __complete autostart enable "${PROJNAME}" ""
  refute_output --partial "${PROJNAME}"
  # Options complete from a prefix, but not after a project name or twice.
  run ddev __complete autostart enable --r
  assert_output --partial "--running"
  run ddev __complete autostart disable --a
  assert_output --partial "--all"
  run ddev __complete autostart enable "${PROJNAME}" --r
  refute_output --partial "--running"
  run ddev __complete autostart disable "${PROJNAME}" --a
  refute_output --partial "--all"
  run ddev __complete autostart enable --running --
  refute_output --partial "--running"
  run ddev __complete autostart disable --all --
  refute_output --partial "--all"

  can_test_systemd || return 0
  cd "${TESTDIR}"

  # The wait-for-Docker step calls docker by its full path.
  DOCKERBIN="$(mktemp -d "${HOME}/tmp/dockerbin.XXXXXX")"
  ln -s "$(command -v docker)" "${DOCKERBIN}/docker"
  run env PATH="${DOCKERBIN}:${PATH}" ddev autostart enable
  assert_success
  run grep '^ExecStartPre=' "${unit_file}"
  assert_output --partial "\"${DOCKERBIN}/docker\" info"
  # At boot no one can type a sudo password, so DDEV mustn't ask for one.
  run grep -x 'Environment="DDEV_NONINTERACTIVE=true"' "${unit_file}"
  assert_success
  # Two projects starting at once race to create DDEV's network; one at a time.
  run grep '^ExecStart=' "${unit_file}"
  assert_output --partial 'flock -o '

  # After `disable`, Tab offers the projects registered by this user (via the
  # plugin's plugin_list_registered), so this one now appears.
  run ddev __complete autostart disable ""
  assert_output --partial "--all"
  assert_output --partial "${PROJNAME}"

  # A unit that's installed but was disabled behind our back is re-enabled,
  # not reported as "already configured".
  sudo systemctl disable "${UNIT}"
  run env PATH="${DOCKERBIN}:${PATH}" ddev autostart enable
  assert_success
  assert_output --partial "enabled again"
  run systemctl is-enabled "${UNIT}"
  assert_output "enabled"
  run ddev autostart disable
  assert_success

  # DOCKER_HOST set in the environment is carried into the service.
  run env DOCKER_HOST="unix:///var/run/docker.sock" ddev autostart enable
  assert_success
  run grep '^Environment="DOCKER_HOST=unix:///var/run/docker.sock"$' "${unit_file}"
  assert_success
  run systemd-analyze verify "${unit_file}"
  assert_success
  run ddev autostart disable
  assert_success

  # So is DOCKER_CONFIG, where `docker context use` stores the chosen context.
  local docker_config
  docker_config="$(mktemp -d "${HOME}/tmp/dockerconfig.XXXXXX")"
  run env DOCKER_CONFIG="${docker_config}" ddev autostart enable
  assert_success
  run grep -x "Environment=\"DOCKER_CONFIG=${docker_config}\"" "${unit_file}"
  assert_success
  run ddev autostart disable
  assert_success
  rm -rf "${docker_config}"

  # A ddev-autostart-*.service we didn't write is never changed or removed.
  printf '[Unit]\nDescription=Not ours\n[Service]\nType=oneshot\nExecStart=/bin/true\n' |
    sudo tee "${unit_file}" >/dev/null
  run ddev autostart enable
  assert_failure
  assert_output --partial "wasn't created by ddev autostart"
  run ddev autostart disable
  assert_failure
  assert_output --partial "wasn't created by ddev autostart"
  run ddev autostart disable --all
  assert_success
  assert_output --partial "No projects are registered"
  run ddev autostart list
  refute_output --partial "orphaned"
  run grep -c "Not ours" "${unit_file}"
  assert_output "1"

  # A unit this add-on wrote for another Linux user is never changed or removed:
  # not by enable, disable, disable --all (which uninstalling uses) or list.
  printf '# Managed by ddev-autostart. Do not edit.\n[Unit]\nDescription=Another user\n[Service]\nType=oneshot\nUser=nobody\nExecStart=/bin/true\n' |
    sudo tee "${unit_file}" >/dev/null
  run ddev autostart enable
  assert_failure
  assert_output --partial "registered by user 'nobody', not you"
  run ddev autostart disable
  assert_failure
  assert_output --partial "registered by user 'nobody', not you"
  run ddev autostart disable --all
  assert_success
  assert_output --partial "No projects are registered"
  run ddev autostart status
  assert_output --partial "registered by user 'nobody', not you"
  run ddev autostart list
  assert_output --regexp "${PROJNAME}[[:space:]]+disabled"
  refute_output --partial "orphaned"
  run grep -c "Another user" "${unit_file}"
  assert_output "1"

  # Only the first line counts: the marker anywhere else doesn't make it ours.
  printf '[Unit]\n# Managed by ddev-autostart.\nDescription=Not ours either\n' |
    sudo tee "${unit_file}" >/dev/null
  run ddev autostart disable
  assert_failure
  assert_output --partial "wasn't created by ddev autostart"
  assert_file_exists "${unit_file}"
  sudo rm -f "${unit_file}"
}

teardown() {
  set -eu -o pipefail
  # Never leave a boot service behind on the test machine.
  if [ -f "/etc/systemd/system/${UNIT}" ] && sudo -n true 2>/dev/null; then
    sudo systemctl disable "${UNIT}" >/dev/null 2>&1 || true
    sudo rm -f "/etc/systemd/system/${UNIT}"
    sudo systemctl daemon-reload || true
  fi
  [ -n "${DOCKERBIN:-}" ] && rm -rf "${DOCKERBIN}"
  ddev add-on remove "${ADDON_NAME}" >/dev/null 2>&1 || true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1
  # Persist TESTDIR if running inside GitHub Actions. Useful for uploading test result artifacts
  # See example at https://github.com/ddev/github-action-add-on-test#preserving-artifacts
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
  fi
}

@test "install from directory" {
  set -eu -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  health_checks
  unreleased_checks
}

@test "remove add-on deletes the command and its boot services" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  run ddev autostart list
  assert_success

  if can_test_systemd; then
    run ddev autostart enable
    assert_success
    assert_file_exists "/etc/systemd/system/${UNIT}"
  fi

  run ddev add-on remove "${ADDON_NAME}"
  assert_success
  run ddev autostart list
  assert_failure

  if can_test_systemd; then
    assert_file_not_exists "/etc/systemd/system/${UNIT}"
    run systemctl is-enabled "${UNIT}"
    assert_failure
  fi
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  health_checks
}

@test "every plugin implements the plugin contract" {
  set -eu -o pipefail
  local plugin fn
  for plugin in "${DIR}"/commands/host/autostart.d/plugins/*.sh; do
    for fn in plugin_enable plugin_disable plugin_status plugin_list_registered; do
      run bash -c 'source "$1" && declare -F "$2" >/dev/null' _ "${plugin}" "${fn}"
      assert_success "$(basename "${plugin}") is missing ${fn}"
    done
  done
}

@test "systemd plugin refuses paths a unit can't hold safely" {
  set -eu -o pipefail
  local lib="${DIR}/commands/host/autostart.d"
  run bash -c 'source "$1/lib/resolve-approot.sh"; source "$1/plugins/systemd.sh"; plugin_enable demo "$2"' _ "${lib}" '/tmp/quote"here'
  assert_failure
  assert_output --partial "quote, backslash or newline"
  run bash -c 'source "$1/lib/resolve-approot.sh"; source "$1/plugins/systemd.sh"; plugin_enable demo "$2"' _ "${lib}" '/tmp/back\slash'
  assert_failure
  assert_output --partial "quote, backslash or newline"
  # A Docker setting the unit can't hold is refused, not silently dropped.
  run env DOCKER_CONFIG='/tmp/docker\config' bash -c 'source "$1/lib/resolve-approot.sh"; source "$1/plugins/systemd.sh"; plugin_enable demo /tmp' _ "${lib}"
  assert_failure
  assert_output --partial "DOCKER_CONFIG contains a quote, backslash or newline"
}

@test "launchd plugin writes, lists and removes a LaunchAgent (fake launchctl)" {
  set -eu -o pipefail
  local lib="${DIR}/commands/host/autostart.d" fake agent
  fake="$(mktemp -d "${HOME}/tmp/launchd.XXXXXX")"
  mkdir -p "${fake}/bin" "${fake}/home"
  # Nothing is loaded and nothing is turned off; every call is recorded.
  cat >"${fake}/bin/launchctl" <<'EOF'
#!/bin/sh
echo "$*" >>"$(dirname "$0")/calls"
case "$1" in
  print) [ -f "$(dirname "$0")/print" ] || exit 113; cat "$(dirname "$0")/print" ;;
  print-disabled)
    if [ -f "$(dirname "$0")/disabled" ]; then cat "$(dirname "$0")/disabled"; else echo "disabled services = {"; echo "}"; fi ;;
esac
EOF
  chmod +x "${fake}/bin/launchctl"
  local call='source "$1/lib/resolve-approot.sh"; source "$1/plugins/launchd.sh"; shift; "$@"'
  launchd() { env HOME="${fake}/home" PATH="${fake}/bin:${PATH}" bash -c "${call}" _ "${lib}" "$@"; }
  agent="${fake}/home/Library/LaunchAgents/ddev-autostart.demo.plist"

  run launchd plugin_enable demo "${TESTDIR}"
  assert_success
  assert_output --partial "will start automatically when you log in"
  assert_file_exists "${agent}"
  run sed -n 2p "${agent}"
  assert_output --partial "<!-- Managed by ddev-autostart."
  if command -v python3 >/dev/null 2>&1; then
    run python3 -c 'import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
assert p["Label"] == "ddev-autostart.demo" and p["WorkingDirectory"] == sys.argv[2]
assert p["RunAtLoad"] and p["AbandonProcessGroup"] and p["ProgramArguments"][6] == "demo"
assert p["EnvironmentVariables"]["DDEV_NONINTERACTIVE"] == "true"
assert "flock" in p["ProgramArguments"][2] and "/.start.lock" in p["ProgramArguments"][2]' "${agent}" "${TESTDIR}"
    assert_success
  fi
  # "--" isn't allowed in an XML comment; the name must not end up in one.
  if command -v python3 >/dev/null 2>&1; then
    run launchd plugin_enable my--site "${TESTDIR}"
    assert_success
    run python3 -c 'import plistlib, sys; plistlib.load(open(sys.argv[1], "rb"))' \
      "${fake}/home/Library/LaunchAgents/ddev-autostart.my--site.plist"
    assert_success
    rm -f "${fake}/home/Library/LaunchAgents/ddev-autostart.my--site.plist"
  fi
  # The start lock: one at a time, and a process `ddev start` leaves running
  # (like Mutagen's daemon) must not keep holding it.
  if command -v perl >/dev/null 2>&1; then
    local lockperl lockfile="${fake}/start.lock" t0
    lockperl="$(bash -c 'source "$1/plugins/launchd.sh"; printf "%s" "$_LD_LOCK_PERL"' _ "${lib}")"
    t0="$(date +%s)"
    run perl -e "${lockperl}" "${lockfile}" sh -c 'sleep 5 >/dev/null 2>&1 & exit 3'
    assert_equal "${status}" 3
    run perl -e "${lockperl}" "${lockfile}" true
    assert_success
    [ "$(( $(date +%s) - t0 ))" -lt 4 ] || fail "a leftover child kept the start lock"
    # Without a usable lock file it still starts, and says so.
    run perl -e "${lockperl}" /nonexistent/dir/start.lock echo started
    assert_success
    assert_output --partial "without the start lock"
    assert_output --partial "started"
  fi

  # enable must not load the agent: loading runs `ddev start` right away.
  run grep -E '^(bootstrap|kickstart)' "${fake}/bin/calls"
  assert_failure

  run launchd plugin_list_registered
  assert_output "$(printf 'demo\tenabled\tinactive')"

  # How each `launchctl print` result is reported (output format of macOS 13+).
  local state expected
  for state in "last exit code = 0:active" "last exit code = 78: EX_CONFIG:failed" \
    "last terminating signal = Terminated: 15:failed"; do
    expected="${state##*:}"
    printf 'gui/501/ddev-autostart.demo = {\n\tstate = not running\n\t%s\n}\n' "${state%:*}" >"${fake}/bin/print"
    run launchd plugin_list_registered
    assert_output "$(printf 'demo\tenabled\t%s' "${expected}")"
  done
  rm -f "${fake}/bin/print"

  # Real output captured on macOS 26 (tests/testdata/launchd), project "site".
  local fixtures="${DIR}/tests/testdata/launchd"
  cp "${agent}" "${fake}/home/Library/LaunchAgents/ddev-autostart.site.plist"
  for state in print-starting:activating print-running:activating \
    print-signal:failed print-exit-78:failed; do
    cp "${fixtures}/${state%%:*}.txt" "${fake}/bin/print"
    run launchd plugin_list_registered
    assert_line "$(printf 'site\tenabled\t%s' "${state##*:}")"
  done
  rm -f "${fake}/bin/print"
  cp "${fixtures}/print-disabled-off.txt" "${fake}/bin/disabled"
  run launchd plugin_list_registered
  assert_line "$(printf 'site\tdisabled\tinactive')"
  cp "${fixtures}/print-disabled-on.txt" "${fake}/bin/disabled"
  run launchd plugin_list_registered
  assert_line "$(printf 'site\tenabled\tinactive')"
  rm -f "${fake}/bin/disabled" "${fake}/home/Library/LaunchAgents/ddev-autostart.site.plist"

  # A job still running (here: just started) is left to finish: no bootout, and
  # its log is kept since the job is still writing to it.
  local log="${fake}/home/Library/Logs/ddev-autostart/demo.log"
  mkdir -p "${log%/*}" && echo "starting" >"${log}"
  cp "${fixtures}/print-starting.txt" "${fake}/bin/print"
  : >"${fake}/bin/calls"
  run launchd plugin_disable demo
  assert_success
  assert_output --partial "left to finish"
  assert_file_not_exists "${agent}"
  assert_file_exists "${log}"
  run grep '^bootout' "${fake}/bin/calls"
  assert_failure
  rm -f "${fake}/bin/print" "${log}"
  run launchd plugin_enable demo "${TESTDIR}"
  assert_success

  # DDEV_XDG_CONFIG_HOME moves DDEV's global config; the job needs it too.
  if command -v python3 >/dev/null 2>&1; then
    run env DDEV_XDG_CONFIG_HOME=/tmp/elsewhere HOME="${fake}/home" PATH="${fake}/bin:${PATH}" \
      bash -c "${call}" _ "${lib}" plugin_enable xdg "${TESTDIR}"
    assert_success
    run python3 -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["EnvironmentVariables"]["DDEV_XDG_CONFIG_HOME"])' \
      "${fake}/home/Library/LaunchAgents/ddev-autostart.xdg.plist"
    assert_output "/tmp/elsewhere"
    rm -f "${fake}/home/Library/LaunchAgents/ddev-autostart.xdg.plist"
  fi

  run launchd plugin_disable demo
  assert_success
  assert_file_not_exists "${agent}"
  run launchd plugin_list_registered
  assert_output ""
  rm -rf "${fake}"
}
