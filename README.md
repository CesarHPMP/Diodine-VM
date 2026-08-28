# Diodine VM — Phase 2 (in progress)

A capability-restricted malware analysis environment.

`diodine.md` is the design document and threat model. `policy/policy.yaml` is
the machine-readable policy: every security claim, where it is enforced, how it
is verified, and — importantly — which claims are **not** enforced yet.

An architecture prototype on commodity Linux, built to be tested rather than
deployed. Do not put live malware in it (see *Scope* below, and the gate in
`BACKLOG.md`).

Phase 1 built the boundary. Phase 2 attacks it, and starts from the lesson Phase
1 actually taught: it found no isolation failure, but it found observability
failures — and then roughly ten failures in the *instruments* used to look for
them, every one of which failed toward a **reassuring** answer. `BACKLOG.md`
records what is deliberately still incomplete.

## Quickstart

```sh
./image/build-base-image        # once: ~48 MB of downloads, checksum-verified
sudo policy/apparmor/install    # once: load the VMM confinement profile
sudo usermod -aG systemd-journal $USER   # once: denial visibility -- then LOG OUT
./bin/diodine-run              # boot a disposable VM, run the default probe
./tests/run-checks              # verify the boundary is configured as claimed
./tests/adversarial/run         # hostile inputs against the receiver and ingest
```

The `install` step is not optional. Without the profile loaded, a run **refuses
to start** and exits 2 (`VMM-002` is fail-closed). If you genuinely want to run
without MAC confinement, `--allow-unconfined` says so explicitly and the waiver
is recorded in that run's `RUN.json`.

The `usermod` step is what makes `AUD-004` work: a confinement profile that
silently refuses something is the failure this project has already had — the
AppArmor NUMA denial fired on *every* confined run while 26/26 checks passed
twice. Reading denials needs journal access, and `TCB-001` forbids Diodine a
privileged component, so the operator grants it once and the launcher stays
unprivileged.

**Log out and back in afterwards.** Supplementary groups are fixed at login, so
`usermod` does not affect the shell you typed it in. Without the grant runs still
work — they record `denials.checked: false` — but `tests/run-checks` **fails**
rather than reporting all-green while blind.

Analysing something:

```sh
./bin/diodine-run --payload ./my-analysis.sh --sample ./suspicious.bin
./bin/diodine-ingest quarantine/<run-id> /tmp/expanded    # bounded expansion
```

The payload runs as root inside the guest. Anything it writes to
`/diodine/out/` is exported; the sample appears at `/diodine/sample/`.

Each run directory separates the two trust domains by layout:

```
quarantine/<run-id>/
    artifacts/       guest-authored. names chosen by the guest, trust nothing
    MANIFEST.json    host-authored. what crossed, with sizes and hashes
    RUN.json         host-authored. the boundary's measured state during the run
    console.log      host-authored. guest kernel and init output
```

Guest names cannot contain a slash, so nothing the guest emits can collide with
a host record no matter what it calls itself (AUD-002).

## How it works

```
  diodine-run
      │
      ├─ receiver ────────── opens ONLY iv.out, O_RDONLY ──┐
      │                                                     │
      └─ systemd-run --scope  (MemoryMax, MemorySwapMax=0,  │
           │                   CPUQuota, TasksMax)          │
           └─ qemu -nodefaults -sandbox on -nic none        │
                │                                           │
                │  RAM-only guest: kernel + initramfs,      │
                │  no disk, no NIC, no USB, no GPU          │
                │                                           │
                └─ virtio-serial ──▶ iv.out (FIFO) ─────────┘
                                     iv.in  (FIFO, no writer ever)
                                            │
                                            ▼
                                   quarantine/<run-id>/artifacts/
                                            │
                                   diodine-ingest (bounded)
```

Four decisions carry most of the security value:

**The guest has no block device.** The whole userland is an initramfs in RAM.
Nothing persists across runs, and the base image cannot be modified because it
is never mounted. Disposability is structural rather than procedural.

**No filesystem crosses the boundary.** The guest emits a length-prefixed byte
stream; the host copies bytes to files and never parses them. Mounting a
guest-authored filesystem would hand a compromised guest the host kernel's ext4
or NTFS parser, which is exactly the attack this design exists to avoid.

**Directionality is a property of which descriptors exist.** QEMU's pipe
chardev uses a FIFO pair: it writes guest output to `iv.out` and reads host
input from `iv.in`. The receiver opens only `iv.out`, only `O_RDONLY`, and
nothing in the project ever opens `iv.in`. With no writer, the guest's reads
see EOF forever. This survives a compromised receiver, and `tests/run-checks`
verifies it both from inside the guest and by auditing the code.

**Limits are enforced on the host side, while streaming.** Export caps are
applied as bytes arrive, before they reach disk; decompression bounds are
charged against a single global budget so a bomb cannot buy room by nesting.

## What is and is not enforced

Verified by `tests/run-checks` (58 checks): no network interface, no USB, no
graphics, no shared folders, no block device, one sanctioned virtio port, no
host entropy source, nothing on the PCI bus but the chipset and the one virtio
device, guest-side readback yields nothing, the memory, swap, CPU and task caps
read back from the run's own cgroup, export caps enforced mid-stream, wall-clock
destruction of a non-cooperative guest, base image byte-identical after a run,
ingest refusal of zip bombs, path traversal and symlink members, every run
recording its own measured confinement state, host records surviving a guest
that emits artifacts named after them, a run refusing to start at all when the
confinement profile is missing, the retention and consumer warnings both firing
when they should and staying quiet when they should not, and — since the harness
now reads `policy.yaml` — that every statement in it is checked here or exempted
with its reason (`AUD-003`).

Known gaps, all recorded in `policy/policy.yaml`:

| ID | Gap |
| --- | --- |
| `OUT-002` | The channel is directional, not perfectly one-way. **Measured** (`tests/out002/`): buffer depth 585728 bytes, detection floor ~8 ms, and ~450 symbols per run — capacity is bounded by `RES-006`'s byte cap, since each symbol costs the guest ~0.56 MiB of export budget. Raising `--max-total` raises it proportionally. |
| `RES-008` | Nothing *bounds* quarantine growth **across** runs — `RES-006` caps one run at 256 MB and nothing caps the count. Every run now reports the cumulative total and warns past `--quarantine-warn-mb` (default 5000). Nothing prunes automatically; retention is yours. |
| `QUAR-001` | Quarantine exclusion markers are advisory. A startup scan now names any indexer, thumbnailer, AV or backup agent that is running, and records it in `RUN.json` — but it warns rather than blocks, and configuring those tools to skip the directory is still out of band. |
| `PLAT-001` | Microarchitectural side channels are inherited from the platform and out of scope. |

`RES-007` used to sit in that table. It is now a **decision**, not a gap: the
console stays outside the export caps because `-chardev file` never blocks QEMU,
so it carries no backpressure and no timing channel. Capping it would mean a
bounded writer, which would buy a byte cap at the price of a second
`OUT-002`-style covert channel — a bad trade against a 9 MB write. The launcher
warns if `--timeout` goes past an hour, where that figure stops being small.

## Layout

```
diodine.md              design document and threat model
LICENSE                 GNU GPL v3 (verbatim); see Licence below
NEXT.md                 Phase 2 plan: workstreams, test rules, live-sample gate
BACKLOG.md              deferred BY DESIGN, with what would close each item
policy/policy.yaml      every claim, its enforcement point, its status
policy/apparmor/        VMM confinement profile and installer
bin/diodine-run         hardened launcher; the QEMU args ARE the policy
bin/diodine-receiver    host-side output receiver; parses nothing
bin/diodine-ingest      bounded decompression; the only thing that parses
guest/init              guest PID 1
guest/diodine-send      guest-side artifact emitter
image/build-base-image  builds the RAM-only Alpine base
tests/run-checks        verification harness, keyed to policy IDs
tests/adversarial/      Phase 2 hostile-input suite (frames, ingest)
quarantine/             untrusted output (gitignored)
```

`bin/diodine-run --help` lists every knob. Reading the `ARGS` array in that
script tells you the guest's entire hardware attack surface — `-nodefaults`
means nothing is attached that is not named there.

## Scope

Phase 1 demonstrates and tests the isolation model with **synthetic** hostile
workloads. Live malware should not be introduced until Phase 2 has shown the
boundary holds against deliberate attack, and not on hardware or a network that
matters. The guest has no network by design; giving it one means taking
responsibility for what leaves the machine.

Nothing arriving in `quarantine/` is trustworthy. That is the point of the
directory, not a caveat about it.

## Licence

Diodine VM is free software under the **GNU General Public License, version 3 or
later**. `LICENSE` is the verbatim GPL-3.0 text; every source file carries an
SPDX identifier rather than a repeated copy of the notice.

    Copyright (C) 2026 César Henrique Policarpo de Melo

    This program is free software: you can redistribute it and/or modify it
    under the terms of the GNU General Public License as published by the Free
    Software Foundation, either version 3 of the License, or (at your option)
    any later version.

    This program is distributed in the hope that it will be useful, but WITHOUT
    ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
    FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
    more details.

The warranty disclaimer above is the licence's, and it is legal boilerplate. It
is **not** the safety statement — that is *Scope*, above, and it is the one that
actually matters here. A licence says nothing about whether a boundary holds.

The Alpine minirootfs and kernel are **downloaded at build time** by
`image/build-base-image`, not redistributed in this repository, so their own
licences apply to what lands in `image/base/` rather than to this source tree.
An image built here and then shipped elsewhere would carry them.
