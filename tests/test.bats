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

  export GITHUB_REPO=asiby/ddev.d
  export ADDON_NAME=ddev.d

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
