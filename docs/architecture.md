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
- The helper never reverts anything on its own

## The second decision: the setting is enforced, not just written

Writing a value once makes the app a suggestion. Anything else that writes
`pmset` — another utility, a script, a system update — silently wins, and the
user is left with a menu that says one thing and a Mac that does another.

So while a switch is on, the helper keeps it on. It records what the user asked
for, watches for the settings moving, and puts them back.

Authority is scoped to the switches that are on. A setting whose switch is off
belongs to the user: another app changing it is not drift, it is none of our
business. Enforcing those too would mean fighting the user's own `pmset` over
values they never asked us to hold.

This is why the helper runs continuously (`RunAtLoad` + `KeepAlive`) rather than
on demand. On demand meant the daemon only started when the app connected, so
the rule lapsed at every reboot until someone opened the app — and the app is
not required to run.

Enforcing and reverting stay opposites. Nothing is undone without an explicit
"off"; what is enforced is only ever what the user switched on.

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
| `HelperService` | Applies settings, owns the baseline, re-asserts the rule. Runs as root. |
| `PmsetControl` | Runs `/usr/bin/pmset`, parses `pmset -g`. |
| `BaselineStore` | Where the machine came from. Root-only plist. |
| `DesiredStore` | Where it must stay. Root-only plist. |
| `PowerEnforcement` | Pure rule: given the switches and the machine, what must be rewritten. |
| `PowerWatcher` | Notices the settings moving — file watches plus a timer. |
| `PowerPreferences` | Finds the preference files, whose names cannot be hard-coded. |

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

## Enforcement

Two records, opposite jobs. `baseline.plist` is where the machine came from;
`desired.plist` is where it must stay. Both are released together when every
switch goes off — at that point the app claims nothing and enforces nothing.

`PowerWatcher` triggers a check from two independent sources, because neither
alone is enough:

- **File watches** on the power management preferences, for an immediate
  reaction. There is more than one such file — a plain one and a per-machine
  one whose name contains a UUID — and which of them a write lands in varies, so
  all of them are watched, found by name rather than hard-coded.
- **A timer**, because not every route into those settings goes through those
  files, because a file can appear after we started, and because a file watch
  can be lost without saying so.

`pmset` replaces the preference file rather than editing it, so a watch holding
a descriptor to the old file goes deaf after the first change. The watcher
re-opens the path, and reports a change across the gap it was deaf for: a write
that already happened is exactly what would otherwise be missed.

Extra checks are cheap by design — `PowerEnforcement.correction` returns nil
when the machine already obeys, and nothing is written — so the watcher errs
towards checking too often rather than missing a change.

The helper also enforces once at startup, which covers a reboot, a system update
or anything that moved the settings while it was not running.

### Upgrading from a version that only wrote settings

Those versions left a baseline but no rule, so a machine whose switches are on
arrives with nothing to enforce — the user would stay unprotected until they
happened to toggle something. At startup the helper adopts what is in effect as
the rule.

The baseline is what makes this safe. Its existence is the marker that this app
owns the machine's settings; without one nothing is claimed, because values on a
machine this app never touched belong to whoever set them. An existing rule is
never re-derived either — otherwise drift would quietly become the new rule.

## What the settings cannot win against

`pmset` writes settings; an `IOPMAssertion` overrides them while it is held. A
machine can obey every setting this app writes and still refuse to sleep, with
nothing in the settings to explain it — which reads as "this app does not work".

So the helper reads `pmset -g assertions` and Settings names who is holding the
Mac awake. Two things are filtered out, and the reasoning matters:

- **`powerd`** asserts "Prevent sleep while display is on" on every Mac whose
  screen is lit. Reporting the operating system's own bookkeeping would be noise
  on a healthy machine and would bury the real culprit.
- **`UserIsActive`** means someone touched the keyboard. Not a reason the
  machine is refusing to sleep.

This is reporting, not enforcement. An assertion belongs to the process holding
it; taking it away is not this app's business.

## Baseline

Before the first change the helper records the machine's own values.

- Later changes never overwrite that record; the first true value wins
- Switching one thing off restores that one value
- Switching everything off restores all of them and deletes the record
- If a write cannot be verified the record is kept, so a later attempt can retry

### The trap this sets, and the way out

"The machine's own values" are whatever it happened to have the first time a
switch was flipped. If something had already set `displaysleep 0` — another
utility, an earlier version of this app, the user's own `pmset` — then "never
sleep" is recorded as the machine's normal. Switching everything off faithfully
restores it and then releases the baseline: the display stays on for good, and
there is nothing left in the app to undo it. The app is behaving correctly and
the user is stuck.

**Restore Defaults** in Settings is the way out: `pmset restoredefaults`, then
both records released. Both, not just the baseline — a rule left behind would be
re-asserted by the next enforcement pass and quietly undo the restore. If the
restore itself fails the records are kept, because dropping them would strand
the user with settings the app no longer admits to owning.

## macOS behaviour this code accounts for

Each is guarded by a test or a comment.

**`pmset -g` contains `Sleep On Power Button 1`.** Its first field lowercases to
`sleep`, and its second field is not a number. A parser that stops there never
reads the real `sleep` line and silently reports `0`. Parser fixtures in this
repo are verbatim captures of real output for exactly this reason.

**`SMAppService.status` can lie, in both directions.** A stale Background Task
Management record keeps reporting `.enabled` after the launchd job is gone —
even after the app is deleted. It also reports `.notFound` for a daemon that is
registered, running and answering: that is what `sfltool resetbtm` leaves
behind, and the Settings window read it straight, telling the user the helper
was not installed while it was working perfectly.

Neither signal is trustworthy alone, so `HelperInstallationState.resolve`
combines them. Answering plus no record is its own state — `orphaned`: it works
now, it will not survive a reboot, and the app cannot heal it by itself, because
registration only ever happens for a helper that is *not* answering. Settings
offers Repair for exactly that.

**Registration is not reliably immediate.** `register()` fails with "Operation
not permitted" for a few seconds after the same service was unregistered, while
launchd lets go of the old job. Attempting it once is how the machine ends up
with no registration at all, so `HelperRegistration.attempt` retries and the
failure is reported rather than logged and swallowed.

**launchd will not release a registration whose job is still running.** This is
what makes an ordinary update — replace the bundle while the old helper is
alive — leave the old record in place, holding a bookmark to a bundle that no
longer exists. The daemon then dies with `EX_CONFIG` on every spawn.

So the helper has a `quit()` method and the app asks it to exit before touching
the registration. Exiting reverts nothing: a setting written by the helper
belongs to the system, not to that process.

`KeepAlive` brings the daemon straight back, which is why the app does *not*
wait for it to stay gone — that condition never becomes true and would only burn
a timeout. A short pause covers what matters: the process being replaced has
ended.

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
