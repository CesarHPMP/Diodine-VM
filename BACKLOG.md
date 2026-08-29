# Diodine VM — deferred by design

Everything here is **incomplete on purpose**, not by oversight. Each entry says
what would close it, and what it currently blocks. `NEXT.md` is the Phase 2 plan;
this is the part of that plan deliberately not being executed yet.

The rule that governs this file: an entry may sit here indefinitely, but it may
not sit here *silently*. If something in `policy.yaml` depends on an entry below,
the statement says so and carries the honest status.

---

## W5 — Portability. Every number is single-host.

**Status: open. Blocks W8 gate item 3.**

Every figure this project has measured comes from one machine:

    kernel           6.12.101+deb13-amd64
    qemu             10.0.11 (Debian 1:10.0.11+ds-0+deb13u1)
    apparmor_parser  4.1.0

`RES-007`'s ~50 KB/s console ceiling, `OUT-002`'s 585,728-byte buffer depth, and
the AppArmor profile's completeness are all version-dependent properties. The
profile's own header already says it has been exercised on no other host.

**Landed already:** `RUN.json` now records kernel, QEMU and `apparmor_parser`
versions under `host`. That is the prerequisite, not the work — without it, a
number collected today could not be attributed to a platform later, and deferring
the rest would stop being honest.

**To close:** run the whole suite on at least one different kernel and QEMU, and
record both platforms' numbers beside each other.

**Routes considered:**

| route | verdict |
| --- | --- |
| Docker | **useless here** — containers share this kernel; only the QEMU version would differ |
| Nested VM on this host | genuine second kernel + QEMU, but nested KVM distorts the `RES-007` and `OUT-002` timings. Profile completeness is the trustworthy part; treat the timings as indicative only |
| Second physical machine | the real answer |

## W4 — `OUT-002`, deeper

**Status: open. Does not block the gate; `OUT-002` is already `measured`.**

Phase 1 measured on-off keying. Still open:

- **Pulse-width capacity.** Duration fidelity was excellent on long stalls (19.02 s
  against 20.00 s commanded; five repeats within 3 ms), so a symbol probably
  carries several bits. The per-run total stays byte-capped, so the number that
  matters is bits-per-symbol × ~450.
- **The self-noise floor.** At full speed the receiver stalls on its own — it
  hashes and writes to disk — producing blocking writes indistinguishable from
  signal. That may be the real bound rather than the buffer depth.
- **The `--max-total` coupling.** Capacity scales linearly with the export cap.
  Anyone raising `--max-total` for a legitimate reason widens this channel, and
  that deserves a warning in the launcher, not just a line in `policy.yaml`.
- **Cross-host variance.** Buffer depth was identical across runs here, but it is
  a QEMU/kernel property. Folds into W5.

## W6 — `QUAR-001`, structurally

**Status: open, and partly outside Diodine's reach. `QUAR-001` is `partial` and says so.**

Detection landed in Phase 1: the launcher names any indexer, thumbnailer, AV or
backup agent running, and records it per run. Markers are advisory and always will
be — Diodine cannot make a third-party agent honour them.

What would actually change the property is a host decision: a dedicated filesystem
for `quarantine/` mounted `nodev,nosuid,noexec` with a quota. It currently sits on
`/` with plain `rw,relatime`, so nothing structural separates it from the rest of
`$HOME`.

**Needs host-level mount changes, authorised separately.** Also worth testing
empirically: whether artifacts at mode `0400` inside a `0700` directory are enough
to keep a *running* indexer out, with one actually installed.

## W7 — `RES-008`, retention

**Status: open by choice. `RES-008` is `not-enforced` and says so.**

Reporting landed — cumulative size is printed after every run and warns past
`--quarantine-warn-mb`. Reporting is not a bound and the status stays
`not-enforced`.

If a bound is wanted, the honest options are a filesystem quota or an explicit
operator-configured retention policy. **Neither should be automatic deletion
inside `diodine-run`.** Auto-pruning quarantined output is the kind of
helpfulness that destroys the evidence someone came back for.

---

## W8 — The live-sample gate

No live malware until every line reads **done**.

| # | condition | status |
| --- | --- | --- |
| 1 | W1 — denials visible, or explicitly recorded as unchecked | **done** — `AUD-004`; host needs the one-time `systemd-journal` grant, and `tests/run-checks` fails when it is missing |
| 2 | W2 — adversarial suite exists, every check demonstrated failing | **done** — 91 cases across framing, ingest, exhaustion and confinement; controls and driven failures throughout. Found `ING-003`, `OUT-004`, `AUD-005` and its confused-deputy tail, corrected `RES-003` |
| 3 | W5 — results reproduced on a second platform | **open** — see above |
| 4 | `RES-007` decided, not merely documented | **done** — decided uncapped, `policy.yaml` carries the reasoning |
| 5 | Not on hardware or a network that matters | **open** — operator judgement, per the existing scope note |
| 6 | Network still absent | **holds** — `NET-001`/`NET-002`. Giving the guest one means owning what leaves the machine, and nothing in Phase 1 or 2 addresses egress |

## Non-goals — not backlog, excluded

- **`PLAT-001`.** Microarchitectural side channels stay inherited from the
  platform. A claim that cannot be verified is worse than a stated exclusion.
- **Production hardening.** Phase 2 is a prototype being tested, not a platform
  being deployed.
- **Guest-side controls.** The payload runs as root in the hostile domain by
  design; nothing it does is a security control, and adding checks there would be
  theatre.
