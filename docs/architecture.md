# Architecture

Small app, one unusual decision, a handful of macOS traps worth knowing about.

## The one decision that shapes everything

**Settings live in the system, not in the app.**

This is a configuration tool, not a background service. Flipping a switch writes
a `pmset` value and that value stays — through quitting, crashing and rebooting.
Nothing is reverted unless the user explicitly switches it off.

That rules out the obvious implementation. `IOPMAssertion` — the API most
"keep awake" apps use — ties wakefulness to the process holding it, so the
setting dies with the app. Correct for a stay-resident utility, wrong here.

Consequences, each of them something the code deliberately does *not* do:

- No cleanup when the app quits
- No cleanup when the XPC connection drops
- No recovery pass at boot
- The helper never reverts anything on its own

## Pieces

```
Keep Mac Awake.app
├─ Contents/MacOS/KeepMacAwake                       menu bar app (LSUIElement)
├─ Contents/MacOS/…keep-mac-awake.helper             privileged daemon
└─ Contents/Library/LaunchDaemons/…helper.plist      filename must equal Label
```

| Unit | Responsibility |
|---|---|
| `MenuController` | The menu. Checkmarks reflect what the *system* reports. |
| `PowerHelperClient` | XPC to the helper, registration and approval flow. |
| `AppDelegate` | Wiring, errors, replacing a stale helper after an update. |
| `Preferences` | "Launch at login" only. Power settings are never mirrored here. |
| `HelperService` | Applies settings, owns the baseline. Runs as root. |
| `PmsetControl` | Runs `/usr/bin/pmset`, parses `pmset -g`. |
| `BaselineStore` | Root-only plist under `/Library/Application Support`. |

**State has exactly one home and it is the operating system.** The menu asks the
helper for `currentConfig()` rather than remembering what it last wrote. Keeping
a second copy in `UserDefaults` is how the menu ends up disagreeing with the
machine after a reboot, or after someone runs `pmset` by hand.

## The three settings

| Switch | Writes |
|---|---|
| Keep Awake | `pmset -a sleep 0` |
| Keep display on | `pmset -a displaysleep 0` |
| Stay awake with lid closed | `pmset -a disablesleep 1` |

`-a` covers every power profile, which is what makes a setting survive
unplugging the charger.

## Why there is a privileged helper

`pmset -a` needs root and no entitlement grants a normal app that. An embedded
daemon is registered with `SMAppService`; macOS asks the user to approve it once
in System Settings › Login Items, and never again.

The helper is deliberately small: write the setting, remember the machine's
original values, answer three XPC methods. Root-privileged code should be
boring.

Only a binary signed by the same team and carrying the app's bundle identifier
may connect — enforced with `setCodeSigningRequirement` on the listener side.

## Baseline

Before the first change the helper records the machine's own values.

- Later changes never overwrite that record; the first true value wins
- Switching one thing off restores that one value
- Switching everything off restores all of them and deletes the record
- If a write cannot be verified the record is kept, so a later attempt can retry

## macOS behaviour this code accounts for

Each is guarded by a test or a comment.

**`pmset -g` contains `Sleep On Power Button 1`.** Its first field lowercases to
`sleep`, and its second field is not a number. A parser that stops there never
reads the real `sleep` line and silently reports `0`. Parser fixtures in this
repo are verbatim captures of real output for exactly this reason.

**`SMAppService.status` can lie.** A stale Background Task Management record
keeps reporting `.enabled` after the launchd job is gone — even after the app is
deleted. The only reliable test is whether the helper answers, so
`prepareHelper()` probes first and registers only if it does not.

**Replacing the app leaves the old helper running.** launchd does not restart a
daemon because its bundle changed, so a fix shipped in the app never reaches the
machine. The app compares its build number against the running helper's and
re-registers on a mismatch. This is why the release script increments the build
number every time.

**`pmset` can exit 0 without the value taking effect.** Writes are read back and
retried.

**Invalidating your own XPC connection looks like a crash.** The handler runs
asynchronously, so a "I'm doing this on purpose" flag is already false by the
time it fires; compare connection identity instead.

**`xcodebuild` does not forward shell environment into a host-less test bundle.**
Device-gated tests therefore live behind a separate scheme rather than an
environment variable.

**Installing with `ditto`/`scp` triggers App Translocation**, which runs the app
from a randomised read-only path where `SMAppService` registration fails.
Dragging from the DMG in Finder does not.

## Testing

Unit tests cover the parser, the baseline contract, "nothing is reverted without
an explicit off", the retry path and the failure paths.

Device tests (separate scheme) read the real machine: they parse live `pmset -g`
output and compare against the same values extracted independently with `awk`,
whose case-sensitive matching cannot repeat the parser's mistake. Two
independent readings agreeing is worth more than any fixture.
