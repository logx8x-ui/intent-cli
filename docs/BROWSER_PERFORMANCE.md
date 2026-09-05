# Browser Guard background work — September 5, 2026

Browser Guard 0.2.3 and later reduce avoidable work in Firefox and Chrome:

- Ordinary tab events do not enqueue snapshot timers while no intention is active.
  Forced snapshots still clear the native tab switcher at session end.
- Heartbeats run every three seconds instead of two (20 rather than 30 per
  minute), within the desktop app's five-second readiness window. Rule changes
  still arrive over the native connection immediately; enforcement is event-driven.
- All connection entry points respect an existing reconnect timer. Previously,
  heartbeat and snapshot callbacks could bypass exponential backoff and repeatedly
  launch a missing or failing native host.

The fake-clock regression test in scripts/test-browser-idle-work.cjs exercises
two minutes of disconnected operation with frequent callbacks. The fixed code
attempts eight connections, at the intended exponential-backoff times. The old
code fails this test. One thousand inactive snapshot events create no timers or
tab enumeration, while a forced empty snapshot remains supported.

Firefox/Chrome behavior tests, the new performance regression, release assertions,
Firefox lint (zero errors and warnings), and both extension packages passed.

## Limits of the live observation

During an approximately eight-second sample while Logan was using the Mac, the
Firefox parent process registered 12.5%, 6.8%, and 3.1% CPU after the initial
sample; IntentNativeHost registered 0.1%, 0.0%, and 0.2%. These are not controlled
idle measurements or total Firefox process-tree energy measurements. The macOS
significant-energy indicator alone cannot attribute consumption to this extension.
Other Firefox content processes were also active.

No battery-life percentage improvement is claimed. A controlled before/after
profile with the same tabs and workload remains necessary. The desktop app and
native-host binaries did not change
in this optimization.

Mozilla signed 0.2.4 on September 5. The installed XPI matches the submitted
package (manifest compared structurally); the running native heartbeat reports
0.2.4 and single-startup-launch-v1. The signed GitHub release asset SHA-256 is
dc55e31761be9f81e42baf3e2b46dafd26b8f864dc7c3eae78073834162e8992.
These installation checks are not a controlled battery benchmark.
