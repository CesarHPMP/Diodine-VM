# Ironveil — Phase 1

A capability-restricted malware analysis environment.

`ironveil.md` is the design document and threat model. `policy/policy.yaml` is
the machine-readable policy: every security claim, where it is enforced, how it
is verified, and — importantly — which claims are **not** enforced yet.

This is Phase 1: an architecture prototype on commodity Linux, built to be
tested rather than deployed. Do not put live malware in it (see *Scope* below).

## Quickstart

```sh
./image/build-base-image        # once: ~48 MB of downloads, checksum-verified
./bin/ironveil-run              # boot a disposable VM, run the default probe
./tests/run-checks              # verify the boundary is configured as claimed
```

Analysing something:

```sh
./bin/ironveil-run --payload ./my-analysis.sh --sample ./suspicious.bin
./bin/ironveil-ingest quarantine/<run-id> /tmp/expanded    # bounded expansion
```

The payload runs as root inside the guest. Anything it writes to
`/ironveil/out/` is exported; the sample appears at `/ironveil/sample/`.

## How it works

```
  ironveil-run
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
                                   quarantine/<run-id>/
                                            │
                                   ironveil-ingest (bounded)
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

Verified by `tests/run-checks` (26 checks): no network interface, no USB, no
graphics, no shared folders, no block device, one sanctioned virtio port, no
host entropy source, guest-side readback yields nothing, export caps enforced
mid-stream, wall-clock destruction of a non-cooperative guest, base image
byte-identical after a run, and ingest refusal of zip bombs, path traversal,
and symlink members.

Known gaps, all recorded in `policy/policy.yaml`:

| ID | Gap |
| --- | --- |
| `OUT-002` | The channel is directional, not perfectly one-way. Flow control is a low-bandwidth reverse channel. Phase 2 must **measure** it, not assume it is zero. |
| `RES-004` | Disk I/O bandwidth is uncapped: the `io` cgroup controller is not delegated to the user slice, so an unprivileged scope cannot set it. |
| `VMM-002` | AppArmor confinement requires loading the profile once as root (`sudo policy/apparmor/install`). Without it, runs proceed unconfined and say so. |
| `QUAR-001` | Quarantine exclusion markers are advisory. Any indexer, AV, or backup agent that ignores them must be configured out of band. |
| `PLAT-001` | Microarchitectural side channels are inherited from the platform and out of scope. |

## Layout

```
ironveil.md              design document and threat model
policy/policy.yaml       every claim, its enforcement point, its status
policy/apparmor/         VMM confinement profile and installer
bin/ironveil-run         hardened launcher; the QEMU args ARE the policy
bin/ironveil-receiver    host-side output receiver; parses nothing
bin/ironveil-ingest      bounded decompression; the only thing that parses
guest/init               guest PID 1
guest/ironveil-send      guest-side artifact emitter
image/build-base-image   builds the RAM-only Alpine base
tests/run-checks         verification harness, keyed to policy IDs
quarantine/              untrusted output (gitignored)
```

`bin/ironveil-run --help` lists every knob. Reading the `ARGS` array in that
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
