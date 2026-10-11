# Contributing

Thanks for helping. The most useful contributions right now are plugins for systems I can't test myself: Linux with OpenRC (Alpine, Gentoo) and Windows. If you use one of those, see the open "help wanted" issues.

## How the add-on is organised

```
commands/host/
  autostart                   the command: argument parsing, project lookup, output
  autocomplete/autostart      Tab completion
  autostart.d/
    lib/detect.sh             picks the plugin for this system
    lib/resolve-approot.sh    finds projects and their folders
    lib/list.sh               the `list` table
    plugins/systemd.sh        Linux with systemd
    plugins/launchd.sh        macOS
    bin/ddev-autostart        the macOS login job that launchd runs
tests/
  test.bats                   Bats tests, run in CI
  testdata/launchd/           real `launchctl` output used by the tests
```

Everything system-specific lives in one plugin file (plus, for macOS, the script its login jobs run). The command, `list`, `disable --all`, uninstalling and Tab completion all work through the plugin, so a new plugin gets them without changes elsewhere. (The command's one-line description in `commands/host/autostart`, which mentions Linux and macOS, needs a word added.)

## The plugin contract

A plugin is `commands/host/autostart.d/plugins/<name>.sh`, sourced by bash. It defines four functions:

| Function | Does |
| -------- | ---- |
| `plugin_enable NAME APPROOT` | Registers the project to start at boot or login. Doesn't start it now. |
| `plugin_disable NAME APPROOT` | Removes the registration. Doesn't stop the project. |
| `plugin_status NAME APPROOT` | Prints a human-readable status. |
| `plugin_list_registered` | Prints one line per registered project: `NAME<TAB>AUTOSTART<TAB>SERVICE`. |

`APPROOT` is empty for `disable` and `status` when the project was deleted or moved; they must still work. `plugin_enable` must be safe to run again on a registered project: `enable --registered` runs it on each one to rewrite it after an update.

In `plugin_list_registered`, AUTOSTART is usually `enabled`, `disabled` or `unknown`, and SERVICE `active`, `inactive`, `failed` or `activating`; other words from the system's own tool can be passed through as they are (the systemd plugin prints what `systemctl` says). `list` treats `failed` specially and adds `orphaned` itself, and `enable --registered` rewrites only projects whose AUTOSTART is `enabled`. It must list only the current user's registrations. Tab completion calls it on every key press, so it has to be quick, never prompt or need `sudo`, change nothing, and print nothing else on stdout.

A plugin can also define `plugin_registered_env NAME`, which prints the `DOCKER_HOST`, `DOCKER_CONTEXT`, `DOCKER_CONFIG` and `DDEV_XDG_CONFIG_HOME` values a registration holds, one `VAR=value` line each. `enable --registered` uses them so a rewritten registration keeps its settings; without it, the current shell's are used.

Each function returns 0 on success and non-zero on failure, with errors on stderr starting with `❌ Error:`.

`lib/detect.sh` picks the plugin. It already returns `openrc` (Linux without systemd, with `rc-service`) and `windows` (`OSTYPE` `msys` or `cygwin`), so those two plugins need no detection changes. Add the platform to the README's "Supported platforms" table and a "How it works" section.

The plugin is sourced by the command, which runs under `set -euo pipefail`, after `lib/resolve-approot.sh` (whose helpers, such as `ddev_autostart_valid_name`, you can use). Tab completion sources it on every key press, and CI sources every plugin on Linux. So sourcing it must have no side effects on any system: only define variables and functions.

`systemd.sh` and `launchd.sh` are the reference implementations. Their header comments explain each design decision.

## What every plugin must do

These come from bugs found while building the first two plugins. Most only showed up on a real machine.

- Only change or remove files this add-on created. Mark each file you write (both plugins put a marker comment near the top) and check for the marker before touching a file.
- Run DDEV as the user who registered the project, never as root.
- Record the full paths of `ddev` and `docker` when `enable` runs. Boot and login jobs don't get the user's terminal PATH. If either is gone at boot, say so in the log and suggest running `ddev autostart enable` again.
- Wait for `docker info` to answer before running `ddev start`, with a limit (about 2 minutes on Linux, 5 on macOS).
- Give the job enough time. Any time limit the system puts on it must cover the Docker wait, up to 10 minutes waiting for the lock (below), and the start itself; systemd's is 1200 seconds for this reason.
- Set `DDEV_NONINTERACTIVE=true` for `ddev start`. Otherwise DDEV may ask for a `sudo` password to edit the hosts file, which a boot job can't answer, and fail.
- Run one `ddev start` at a time. Projects starting together race to create DDEV's shared network and all but one fail. Use a lock that the system releases when the process exits, and make sure `ddev` and the processes it leaves running, such as Mutagen's daemon, don't inherit it. Wait at most 10 minutes for it, then start anyway and say so in the log. See how `systemd.sh` (`flock -o`) and `launchd.sh` (perl, `system()`) do it.
- Copy `DOCKER_HOST`, `DOCKER_CONTEXT`, `DOCKER_CONFIG` and `DDEV_XDG_CONFIG_HOME` into the job when they're set, so it uses the same Docker and DDEV settings as the terminal.
- Don't let a shell parse project paths. Pass them as arguments to a fixed script, and escape them for whatever file format the system uses.
- Don't kill a `ddev start` that's still running when the user runs `disable`.
- Write a log, or say where the system's log is, so `status` can point users to it.
- If `sudo` is needed, respect `DDEV_AUTOSTART_NONINTERACTIVE`: never prompt when it's set, and print the manual steps instead.

## Testing

A plugin has to be tested on the real system. The mocks in CI catch regressions, but they never caught the problems that mattered on macOS: a hosts-file password prompt at login, an unexpected service state, and the start race.

1. Run `ddev autostart enable`, `status`, `list`, `disable` and `disable --all` for a test project.
2. Reboot or log out and in, and check the project started on its own.
3. Do the same with two projects registered, to check they start one at a time.
4. Uninstall with `ddev add-on remove ddev-autostart` and check nothing is left registered.
5. Save the system tool's real output (states such as not registered, running, succeeded, failed, turned off) in `tests/testdata/<plugin>/`, with user names and paths removed. Add a Bats test that feeds it to the plugin through a fake tool, like the launchd test does.

Run the tests with [Bats](https://bats-core.readthedocs.io/): `bats ./tests/test.bats`. They need DDEV and Docker (each test creates a DDEV project) and the bats-assert, bats-file and bats-support libraries; the release test also needs network access (skip it with `--filter-tags '!release'`). Where systemd is running and `sudo` needs no password, they register a real boot service for a temporary project and remove it afterwards; elsewhere those checks are skipped. Run `shellcheck` on any script you change.

Environment variables for development and testing:

| Variable | Effect |
| -------- | ------ |
| `DDEV_AUTOSTART_PLUGIN` | Force a plugin (e.g. `systemd`) instead of detecting the OS |
| `DDEV_AUTOSTART_UNIT_DIR` | Write systemd units to another folder instead of `/etc/systemd/system` |
| `DDEV_AUTOSTART_AGENT_DIR` | Write LaunchAgents to another folder instead of `~/Library/LaunchAgents` |
| `DDEV_AUTOSTART_NONINTERACTIVE` | Never prompt for a `sudo` password; fail with manual steps instead |

## Other rules

- Every file under `commands/host/` must contain `#ddev-generated`, so DDEV can update and remove it.
- Scripts that run on macOS must work with bash 3.2 and BSD tools.
- To try your changes, install from your checkout: `ddev add-on get /path/to/ddev-autostart`.
- In the pull request, describe what you tested and on which system.
