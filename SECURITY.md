<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2026 César Henrique Policarpo de Melo -->

# Security policy

## What this project is

Diodine VM is a **research prototype**, not a deployed product. It is an
architecture experiment on commodity Linux, built to be tested rather than run in
production. `policy/policy.yaml` is the authoritative statement of every security
claim: what is enforced, where, how it is verified, and — importantly — what is
**not** enforced. Read it before reporting anything, because several properties
people might expect are deliberately and openly absent.

Nothing arriving in `quarantine/` is trustworthy. That is the purpose of the
directory, not a caveat about it.

## Do not put live malware in it

The live-sample gate is in `BACKLOG.md` and not every condition is met. Until
they are, this should not be pointed at real samples, and not on hardware or a
network that matters. The guest has no network by design; giving it one means
owning what leaves the machine, and nothing here addresses egress.

## Reporting a vulnerability

Report privately through GitHub's **Report a vulnerability** button under the
Security tab (private vulnerability reporting), not as a public issue, if the
finding would let someone escape or subvert the boundary.

Please include the policy statement id the finding contradicts (`OUT-001`,
`ING-002`, `VMM-002`, …) where one applies, the host details from the affected
run's `RUN.json` (`host.kernel`, `host.qemu`, `host.apparmor_parser`), and a
reproduction. Every number this project has measured comes from a single host,
and `BACKLOG.md` W5 is open precisely because of that, so platform details are
part of the report rather than an afterthought.

There is no bounty and no service-level commitment. This is one person's
research repository.

## What counts as a vulnerability here

A finding is in scope if it contradicts something `policy/policy.yaml` claims.
Concretely, that includes:

- Guest code reaching the host filesystem, host kernel, or any host process.
- Getting bytes **into** the guest through the output channel (`OUT-001`).
- Escaping `diodine-ingest`'s destination directory, or defeating its bounds
  (`ING-001`, `ING-002`).
- Forging, replacing, or suppressing a host-authored record of a run
  (`AUD-002`, `AUD-004`), or defeating expansion attribution (`ING-003`).
- Escaping or evading the resource caps (`RES-001`…`RES-006`).
- Defeating the VMM confinement profile, or making a run report itself confined
  when it was not (`VMM-002`, `AUD-001`).

## What is already known and deliberately not fixed

These are documented, not overlooked. Reporting them tells us nothing new:

- **`PLAT-001`** — microarchitectural side channels (Spectre/MDS class) are
  inherited from the platform and explicitly out of scope. A claim that cannot be
  verified is worse than a stated exclusion.
- **`OUT-002`** — the output channel is directional, not perfectly one-way. The
  guest can modulate the host's drain rate and signal back. This is **measured**,
  not merely acknowledged: buffer depth 585,728 bytes, detection floor ~8 ms,
  ~450 symbols per run, capacity bounded by the export cap. Raising `--max-total`
  widens it proportionally. A better measurement is welcome; a report that the
  channel exists is not a finding.
- **`RES-007`** — guest console output is deliberately outside the export caps,
  at roughly 50 KB/s. `policy.yaml` carries the reasoning: bounding it would buy a
  byte cap at the price of a second timing channel.
- **`RES-008`** — nothing bounds quarantine growth across runs. Reporting is not a
  bound, and the status says `not-enforced`.
- **`QUAR-001`** — quarantine exclusion markers are advisory. Diodine cannot make
  a third-party indexer honour them.
- **Guest-side controls** — the payload runs as root inside the guest by design.
  Nothing it does in there is a security control.
- **`bin/diodine-ingest` is not a memory-safety boundary.** It parses hostile
  archives with Python's `zipfile`/`tarfile`. That is a known, documented
  weakness with a known answer (a second disposable VM) that is not yet built. A
  CVE in those modules is an upstream issue, not a finding here.

## What CI does and does not prove

The CI badge covers static hygiene and the adversarial corpora. It does **not**
run `tests/run-checks`, which needs KVM, a loaded AppArmor profile, a systemd user
scope and journal access — none of which a hosted runner has. A green CI run says
the tree is well-formed and the hostile-input corpora pass. It says nothing about
whether the boundary holds.
