Output of `launchctl print` and `launchctl print-disabled` captured on macOS 26.6.2
(build 25G83), with the user name, project name and unrelated services removed.
The bats tests feed these to the launchd plugin through a fake `launchctl`.

- print-not-loaded.txt: the job isn't loaded (launchctl exits 113)
- print-starting.txt: just bootstrapped, `state = xpcproxy`
- print-running.txt: waiting for Docker, `state = running`
- print-signal.txt: killed with `launchctl kill TERM`, `last terminating signal`
- print-exit-78.txt: project folder missing, `last exit code = 78: EX_CONFIG`
- print-disabled-off.txt / print-disabled-on.txt: after `launchctl disable` / `enable`
