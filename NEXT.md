# Ironveil — Phase 2 plan

`ironveil.md` sketches Phase 2 as "adversarial testing" and lists the surfaces to
attack. This document is the operational version: what to build, in what order,
and what has to be true before live samples are allowed anywhere near it.

## Status

| workstream | status |
| --- | --- |
| **W1** denial visibility | **done** — `AUD-004`. Journal-anchored, unprivileged, availability decided by live read. The launcher records; `tests/run-checks` fails when blind. |
| **W2** adversarial suite | **started** — `tests/adversarial/`, 61 cases against the receiver's framing and ingest. Found `ING-003`. Exhaustion and in-VM cases still to come. |
| **W3** `RES-007` | **decided** — console stays uncapped; `policy.yaml` carries the reasoning, and it is no longer filed as a gap. |
| W4 `OUT-002` deeper | deferred → `BACKLOG.md` |
| W5 portability | deferred → `BACKLOG.md`. Host provenance now lands in `RUN.json` so existing numbers stay attributable. |
| W6 `QUAR-001` structurally | deferred → `BACKLOG.md` |
| W7 `RES-008` retention | deferred → `BACKLOG.md` |
| W8 live-sample gate | gate items 1 and 4 closed, 2 in progress; see `BACKLOG.md` |

The deferrals are recorded in `BACKLOG.md` rather than dropped, so what is
incomplete stays visible. The rest of this document is the original plan, kept
as written for the reasoning it carries.

## Where Phase 1 ended

31 policy statements, 58 checks. By status:

| status | count | which |
| --- | --- | --- |
| `enforced` | 26 | the isolation surface, resource caps, ingest bounds, audit records |
| `measured` | 1 | `OUT-002` |
| `partial` | 2 | `RES-007`, `QUAR-001` |
| `not-enforced` | 1 | `RES-008` |
| `inherited` | 1 | `PLAT-001` |

Three things got numbers during the Phase 1 close-out, and the numbers matter
more than the statuses:

- **`OUT-002`** — buffer depth 585,728 bytes, detection floor ~8 ms, and **~450
  symbols per run**. Capacity is bounded by `RES-006`'s byte cap, because each
  symbol costs the guest ~0.56 MiB of export budget. Raising `--max-total` raises
  this channel proportionally.
- **`RES-007`** — console throughput ~50 KB/s, the emulated 16550 being the
  limit; ~9 MB at the default 180 s budget.
- **`RES-008`** — one afternoon of testing produced 4.8 GB across 76 runs while
  every per-run cap held.

## The lesson that should shape Phase 2

Phase 1's close-out found no isolation failure. The guest never escaped, never
reached the host filesystem, never got a byte back through the channel. What it
did find were **observability and integrity failures** — and then roughly ten
failures in the *instruments* used to look for them.

Real defects found in the product:

- `VMM-002`'s detection required root, which `TCB-001` forbids, so the claim was
  unsatisfiable rather than unmet. Every run was unconfined and said so.
- The AppArmor profile denied QEMU's NUMA probe on every confined run. Invisible:
  26/26 checks passed twice while it fired.
- A guest could replace `MANIFEST.json` — the host's own record of what crossed
  the boundary — by emitting an artifact with that name (`AUD-002`).
- The seccomp reading in `RUN.json` was sampled before QEMU installed its filter,
  making `VMM-001`'s verdict a coin flip.
- Two policy statements described designs that had been replaced.

Failures in the instruments, grouped by class, because the classes recur:

1. **Process identification.** `pgrep -f` matched the shell doing the searching,
   whose own command line contained the pattern. `pgrep -x` silently matched
   nothing because `comm` truncates at 15 characters. `SIGSTOP` on a
   cmdline-matched receiver stopped the pyenv shim while its child kept draining
   — and that one produced a clean, plausible, entirely wrong result ("no
   backpressure up to 512 MB") that was already being written up as a finding.
2. **Checks that could not fail.** An honesty check that only fired when
   `observed=false` on a healthy run. A pulse analyser calling a 10 ms stall
   "cleanly resolved" from one sample that was off by +35 ms, because with `n=1`
   the spread is zero by construction.
3. **Reading the wrong thing.** A `dmesg` pipeline that returned `tail`'s exit
   status, reporting "no denials" from a log it never read. A measurement loop
   that latched onto the *previous* run's `console.log` and produced a flat
   448-byte line.
4. **Shell semantics.** `cp x && decoy &` backgrounds the whole AND-list, so `$!`
   is the subshell and killing it orphans the decoy. Piping `run-checks` to
   `tail` masked a failing exit status.

Every one of those failed toward a *reassuring* answer. That is the single most
important input to Phase 2's design: an adversarial suite whose instruments fail
open will certify a boundary that does not hold.

### Rules for Phase 2 tests

1. **Demonstrate every check failing before trusting it to pass.** Against a
   deliberately broken configuration, a stub, or a crafted input. A check whose
   failure path has never executed is not evidence.
2. **Assert a lower bound alongside every upper bound.** "Below X" is only
   meaningful with "and above zero" — otherwise a dead test passes.
3. **Identify processes by what they hold, not what they are called.** File
   descriptors and cgroup membership are unambiguous; names and command lines are
   not. `modulate` finds the reader by who has `iv.out` open, which is the same
   argument `OUT-001` rests on.
4. **Never pipe a harness into another command.** The exit status is the result.
5. **Measure, don't estimate.** `ironveil.md` guessed the reverse channel at "a
   few bits per second" and the guess was wrong in both directions — the rate is
   far higher, the per-run total far smaller. Every limitation in `policy.yaml`
   should end up with a number and a method to reproduce it.
6. **Prefer stubs over hooks.** The fail-closed test simulates a missing profile
   with a stub `aa-exec` that exits nonzero; the consumer scan is tested with a
   copy of `/bin/sleep` named `clamd`. Neither required a test hook in the
   product, and a hook that weakens the boundary to test it is a bad trade.

## Workstreams

Ordered by what unblocks the most.

### W1 — Denial visibility, and the `TCB-001` tension

**The single highest-value item, and it has a design problem to solve.**

The NUMA denial fired on every confined run, cost nothing visible, and passed
26/26 checks twice. A check that fails a run producing *any* AppArmor denial
would have caught it on day one. But reading the audit log needs root, and
`TCB-001` forbids Ironveil a privileged component.

So the evidence most needed is the evidence the threat model forbids collecting.
Options, none free:

- A one-shot root helper invoked only by `tests/`, never by `ironveil-run` —
  keeps the launcher clean but puts root in the test path.
- Operator-provisioned audit access (group membership, or a systemd unit that
  copies the relevant log lines somewhere readable).
- `dmesg_restrict=0`, which weakens the host generally. Not recommended.
- Accept a denial-count check that only runs when privileges happen to be
  available, and record "not checked" otherwise — honest but weak.

Decide this before building the adversarial suite, because most of that suite's
value depends on noticing when the profile refuses something.

Acceptance: a run that produces an AppArmor denial fails a check, or the run
records that denial-checking was unavailable. Never silence.

### W2 — The adversarial suite

`tests/run-checks` says of itself that it is *not* the adversarial suite — the
payloads are cooperative probes confirming the boundary is configured as claimed.
Phase 2 is hostile workloads trying to break it.

Build against the surfaces `ironveil.md` lists (device and `ioctl` surfaces,
memory mappings and DMA, paravirtual channels, malformed frames aimed at the
receiver, malformed archives aimed at ingest, exhaustion in every dimension), with
each test naming the statement it attacks. New attack, no statement: add the
statement first — that rule is in `policy.yaml`'s header and it held up well.

Specific targets suggested by Phase 1:

- **Malformed framing.** The receiver's header path is the only thing that parses
  guest-controlled structure. Fuzz `name_len`, `size`, magic, truncation at every
  boundary, duplicate names, 255-byte names, and a frame declaring a size the
  guest never delivers.
- **Name-space attacks beyond `AUD-002`.** The fix was structural (artifacts live
  in `artifacts/`), so probe for anything else that shares a namespace with a
  guest-chosen string.
- **Ingest.** Bombs nested exactly at the depth limit, ratios just under the cap,
  archives whose members collide, and mixed-type nesting.
- **Exhaustion.** Every cap in `RES-001`..`RES-008`, from inside, and in
  combination — memory pressure *while* streaming at the export cap *while*
  flooding the console.

Acceptance: every test names a statement; every test has been shown to fail
against a deliberately weakened configuration.

**Landed:** the framing corpus (43 cases, driving `ironveil-receiver` directly)
and the ingest corpus (18 cases). Between them they cover the malformed-framing
and ingest targets above. `AUD-003` now computes coverage against this suite too,
so a statement checked only here is not reported as an uncovered gap.

The suite found `ING-003` — nested archives sharing a basename expanded into one
directory and commingled, at exit 0. Not an escape; an attribution failure, and
the same class as `AUD-002`. Fixed structurally.

It also confirmed the design rules were worth writing down. Two harness bugs and
one useless check turned up *while building it*, all three of the Phase 1 shape:
a stall case that closed the pipe and silently measured truncation instead; a
partial `os.write` that sent 19 bytes fewer than claimed and did the same; and a
namespace check that passed against the unfixed code because it tested only one
of the two plausible directory namings.

**Still to come:** exhaustion (every cap in `RES-001`..`RES-008`, from inside,
and in combination), and the in-VM cases. Note the confound for anything driven
through a guest: `guest/init` runs `ironveil-send` after the payload returns, so
a malformed-frame test in a VM is always followed by a second, well-formed sender
on the same stream. The framing corpus avoids it by driving the receiver
directly; the exhaustion work cannot, and has to account for it.

### W3 — `RES-007`, and the trade-off it forces

The console writes straight to a host file via `-chardev file`, outside the export
caps. QEMU offers no size bound on that backend (checked: `path` and `append`,
nothing else), so bringing it into the budget means replacing it with a second
FIFO drained by a bounded writer — the same shape the artifact path already uses.

**The trade-off:** `-chardev file` is timing-inert because QEMU never blocks on
it. A bounded writer gives console the same backpressure the artifact channel has,
i.e. a *second* `OUT-002`-style timing channel. Capping the console and keeping it
inert are in tension, and the current 50 KB/s ceiling makes the uncapped version
cheap.

Decide deliberately. If the answer is "leave it", say so in the statement and
stop calling it a gap.

### W4 — `OUT-002`, deeper

Phase 1 measured on-off keying. Open questions:

- **Pulse-width capacity.** Duration fidelity was excellent on long stalls (19.02 s
  measured against 20.00 s commanded; five repeats of one stall within 3 ms), so a
  symbol probably carries several bits. The per-run total is still byte-capped, so
  the interesting number is bits-per-symbol × ~450.
- **The self-noise floor.** At full speed the receiver stalls on its own — it
  hashes and writes to disk — producing blocking writes indistinguishable from
  signal. Quantify that noise properly; it may be the real bound rather than the
  buffer depth.
- **The `--max-total` coupling.** Capacity scales linearly with the export cap.
  Anyone raising `--max-total` for a legitimate reason widens this channel, and
  that deserves a warning in the launcher, not just a line in `policy.yaml`.
- **Cross-host variance.** Buffer depth was identical across runs here, but it is a
  QEMU/kernel property and every number is single-host.

### W5 — Portability

Everything measured is from one machine: one kernel, one QEMU, one AppArmor
version. The profile's own header says it has been exercised on no other host.
Phase 2 should run the whole suite on at least one different kernel and QEMU
version, because `RES-007`'s ceiling, `OUT-002`'s buffer depth, and the profile's
completeness are all version-dependent.

Acceptance: `IMAGE.lock`-style provenance for the *host* side too — kernel, QEMU,
AppArmor versions recorded in `RUN.json`, so a number can be attributed to a
platform.

### W6 — `QUAR-001`, structurally

Detection landed in Phase 1; enforcement is a host decision. The step that
actually changes the property: a dedicated filesystem for `quarantine/`, mounted
`nodev,nosuid,noexec`, with a quota. Currently it sits on `/` with plain
`rw,relatime`, so nothing structural separates it from the rest of `$HOME`.

Also worth testing: whether artifacts at mode `0400` inside a `0700` directory are
enough to keep a *running* indexer out, empirically, with one installed.

### W7 — `RES-008`, retention

Reporting landed. If a bound is wanted, the honest options are a filesystem quota
(which `ironveil.md` already lists) or an explicit operator-configured retention
policy. Neither should be automatic deletion inside `ironveil-run`.

### W8 — The live-sample gate

`ironveil.md` is right that live malware waits for Phase 2 to demonstrate the
boundary holds. Concretely, all of these before any real sample:

1. W1 done — denials are visible or explicitly recorded as unchecked.
2. W2 done — the adversarial suite exists, and every check has been demonstrated
   failing.
3. W5 done — results reproduced on a second platform.
4. `RES-007` decided (W3), not merely documented.
5. Not on hardware or a network that matters, per the existing scope note.
6. Network still absent. Giving the guest one means owning what leaves the
   machine, and nothing in Phase 1 or 2 addresses egress.

## Research questions, updated

`ironveil.md` lists ten. Phase 1 answered some:

- **Q7, measured reverse bandwidth** — answered, with caveats (W4).
- **Q9, output storage exhaustion** — partly: per-run caps hold, cross-run is
  `RES-008`, and console is `RES-007`.
- **Q3/Q4, all paths guest→host and host→guest** — improved but not closed. Two
  paths turned up late that nobody had enumerated: the console file and the
  artifact *namespace*. Both were found by accident rather than by an exhaustive
  enumeration, which suggests the enumeration is still incomplete. Redo it
  deliberately: every file descriptor, every shared namespace, every host process
  that touches guest-authored bytes.

The rest stand as written.

## Non-goals

- `PLAT-001`. Microarchitectural side channels stay inherited from the platform.
  A claim that cannot be verified is worse than a stated exclusion.
- Production hardening. Phase 2 is still a prototype being tested, not a platform
  being deployed.
- Guest-side controls. The payload runs as root in the hostile domain by design;
  nothing it does is a security control, and adding checks there would be
  theatre.
