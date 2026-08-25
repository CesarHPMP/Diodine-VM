# Ironveil

> **Ironveil — A capability-restricted malware analysis environment.**

## Concept

Ironveil is a research/prototyping project for a hardened malware-analysis environment built around **capability restriction, compartmentalization, and narrowly defined data boundaries**.

The central idea is not to assume that the analysis VM will remain trustworthy. Instead, the surrounding system should be designed so that even a fully compromised guest has very limited capabilities and cannot cause effects outside its explicitly authorized resource envelope.

Three properties are treated as **separate** throughout this document, because conflating them is the most common design error in this space:

| Property | Question it answers |
| --- | --- |
| **Containment** | Can the guest reach outside its boundary? |
| **Resource safety** | Can the guest exhaust or abuse what it *was* legitimately given? |
| **Output safety** | Can what the guest produced attack whatever consumes it? |

A system can be perfectly contained and still destroy the host through resource exhaustion, or still compromise the analyst through a malicious output artifact.

## Prior Art (Read This Before Building Anything)

This architecture is, structurally, a re-derivation of **Qubes OS**. Qubes already implements:

- compartmentalization into VMs by trust domain
- **disposable VMs** destroyed after each use
- `qrexec` — a narrow, policy-mediated inter-VM transfer channel
- no shared folders, no implicit clipboard, per-domain device assignment
- a dom0 that never touches untrusted data directly

Ironveil should either **adopt Qubes as its base** or explicitly document why it does not. Building the same model from scratch on commodity Linux is a legitimate learning exercise, but it should be a deliberate choice rather than an accident of not having looked.

Other relevant prior art worth reviewing before Phase 1:

- **CAPE / Cuckoo Sandbox** — established automated dynamic-analysis platforms; useful mainly for their instrumentation and evasion-handling, not their isolation model.
- **INetSim / FakeNet-NG** — simulated internet for malware that expects network services.
- **sVirt (SELinux/AppArmor + libvirt)** — per-VM mandatory access control confinement of the QEMU process itself.
- **Data diode literature** — for the difference between *directional* and *one-way*, which matters more than it sounds (see below).

The point of reviewing prior art is not to avoid building. It is to make sure the thing being built is the *unsolved* part.

## Core Architecture

Conceptually:

```text
Host
  ↓
Hardened, compartmentalized host environment
  ↓
Hypervisor / kernel enforcement boundary
  ↓
Hostile / disposable analysis VM
  ↓
Restricted one-way output channel (byte stream)
  ↓
External quarantine storage
  ↓
Independent validation
  ↓
Trusted outer system
```

The intended security model is:

> Assume the analysis VM may be compromised. Make compromise difficult to turn into useful capabilities outside the VM.

## One-Way Data Boundary

A central feature is a deliberately constrained output path.

The desired behavior is approximately:

```text
Untrusted VM
     │
     │ write (byte stream)
     ▼
[directional boundary]
     │
     ▼
Quarantine storage
     │
     │ read
     ▼
Outer / trusted environment
```

This is conceptually similar to a **data diode**: data can leave the hostile environment through a narrowly defined path, while the hostile environment cannot use that same path to retrieve information from the outside.

The important distinction is that this should not merely depend on normal filesystem permissions. If the guest is considered hostile, guest-level restrictions are not sufficient. Directionality must be enforced outside the guest's trust domain.

### Do Not Mount Guest-Authored Filesystems

This is the single most important implementation decision in the project.

If the guest writes a *filesystem* to a virtual disk and the host later mounts it, the host kernel's filesystem parser becomes the first thing the compromised guest attacks. Kernel filesystem drivers (ext4, NTFS, FAT, exFAT, UDF, ISO9660) have a long and continuing history of memory-corruption vulnerabilities reachable from malformed on-disk structures. Mounting untrusted media is a privileged parsing operation on attacker-controlled input, executed in ring 0.

Correct shape:

```text
Guest ──(byte stream over vsock / virtio-serial)──▶ Host receiver (unprivileged)
                                                          │
                                                          ▼
                                                  quarantine file
```

Wrong shape:

```text
Guest ──writes ext4 image──▶ Host `mount` ──▶ host kernel parses hostile metadata
```

Rules:

- The guest emits a **stream of bytes**, framed by a trivial length-prefixed protocol.
- The host-side receiver is an **unprivileged, minimal, memory-safe** program whose entire job is: read N bytes, enforce limits, write to a file. It does not parse content.
- The host **never** mounts, auto-mounts, loop-mounts, thumbnails, indexes, or previews anything the guest produced.
- If a filesystem image must be inspected, do it with a **userspace** parser in a *second* disposable VM — never the host kernel.

### Implementation Note (Phase 1)

The implemented channel is QEMU's **pipe chardev**, which uses a FIFO pair:
QEMU writes guest output to `<path>.out` and reads host input from `<path>.in`.
The receiver opens only `<path>.out`, and only `O_RDONLY`. Nothing in the
project ever opens `<path>.in`, so the inbound FIFO has no writer and the
guest's reads on it return EOF forever.

This matters because directionality becomes a property of **which file
descriptors exist**, not of any program's restraint. It holds even if the
receiver is itself compromised, and it is checkable from the outside by listing
`/proc/<pid>/fd`.

Two earlier candidates were rejected in the process:

- **vsock** requires access to `/dev/vhost-vsock`, which is `root:kvm 0660`.
  Using it means adding the operator to the `kvm` group. Deferred; the FIFO
  pair needs no privilege at all.
- **A unix socket with `shutdown(SHUT_WR)`** looked like the natural way to
  enforce directionality in the kernel, and does not work: the shutdown sends
  EOF to QEMU, whose socket chardev reads that as a disconnect and tears the
  channel down. The FIFO pair gives a strictly stronger guarantee without
  fighting the VMM.

The general lesson is worth keeping: an enforcement mechanism that the VMM
interprets as a failure is not an enforcement mechanism.

### Directional ≠ Perfectly One-Way

Any software channel with flow control leaks information backward. Backpressure, buffer availability, write latency, and acknowledgements all form a low-bandwidth reverse channel — realistically a few bits per second, but not zero.

This is acceptable under this threat model. It must be **stated as a limitation**, not quietly assumed away, otherwise Phase 2 adversarial testing will "prove" a property that was never actually claimed.

The claim Ironveil makes is:

> The guest has no *general-purpose* read capability into the outer environment, and no channel of sufficient bandwidth to exfiltrate meaningful host state.

The claim Ironveil does **not** make:

> Zero bits flow from outside to inside.

Only dedicated hardware gets to make the second claim.

## Enforcement Layers

Possible enforcement points include:

1. **Guest kernel**
   - Can restrict ordinary applications.
   - Not sufficient if the guest kernel itself is compromised. Assume it is.

2. **Virtualization boundary / VMM**
   - The guest kernel becomes untrusted.
   - The hypervisor mediates access to virtual devices and resources.
   - The VMM process itself is attack surface — confine it (unprivileged user, seccomp, sVirt).

3. **Host kernel**
   - Enforces policy around the virtualization and I/O stack.
   - Stronger boundary than guest-level controls, but is also the thing a VM escape lands in.

4. **Purpose-built hardware**
   - A physical one-way mechanism provides a stronger guarantee than software alone.
   - Relevant for high-assurance deployments only.

A strong implementation combines software enforcement with dedicated hardware where necessary.

## Read Restrictions

One proposed implementation uses an innate restriction enforced at the kernel/hypervisor level so that the VM cannot arbitrarily perform reads from protected resources.

The important property is not simply:

> "`read()` is blocked."

It is:

> The hostile VM cannot obtain equivalent read capability through another exposed interface.

That means the design must consider alternative access paths such as:

- `read()` variants
- `mmap`
- `ioctl`
- device interfaces
- shared memory
- virtual peripherals
- DMA
- hypervisor interfaces / paravirtual channels
- shared folders (virtiofs, 9p)
- clipboard integration
- USB passthrough
- GPU acceleration and shared graphics memory
- host networking
- timing/covert channels
- CPU microarchitectural side channels (see below)

The security property should therefore be expressed in terms of **capabilities**, rather than individual syscalls.

### Microarchitectural Side Channels

Spectre/Meltdown-class and MDS-class attacks are cross-VM information leaks that no amount of device-model minimization prevents. Mitigating them is a **platform** decision, not an Ironveil decision:

- keep microcode and host kernel current
- enable relevant CPU mitigations rather than disabling them for performance
- consider disabling SMT/hyperthreading for the analysis host, since several attacks are sibling-thread-dependent
- do not co-locate the analysis VM with anything sensitive on the same physical machine

Document these as **assumptions inherited from the platform**, outside the boundary Ironveil itself enforces.

## Capability-Oriented Security Model

A useful invariant is:

> **Compromise of the analysis VM must not provide the attacker with a capability to read protected host state or cause effects outside the explicitly authorized resource envelope.**

The project should continuously test this invariant adversarially. The VM should receive only the capabilities it actually needs.

```text
Allowed:
    Execute analysis workload
    Consume explicitly provided sample
    Produce analysis artifacts
    Write artifacts to designated output channel

Not allowed:
    Read host filesystem
    Read host credentials
    Access arbitrary host devices
    Modify host processes
    Access arbitrary storage
    Establish unrestricted network connections
    Read from the outer environment
    Reach third parties on the internet
```

## Network Policy and Outbound Harm

Network access is not primarily a privacy question. It is a **harm-containment and legal-exposure** question.

Live malware with internet access will attack third parties from the operator's IP address: scanning, credential stuffing, spam, DDoS participation, C2 registration, worm propagation. That is other people's infrastructure, and it is the operator's name on the packets.

Default posture, in order of preference:

1. **No network at all.** The default for Phase 1. An isolated libvirt network with no forwarding, or no NIC at all.
2. **Simulated internet.** INetSim or FakeNet-NG on an isolated segment, answering DNS/HTTP/TLS/SMTP so that network-dependent samples proceed far enough to be observed. This covers most analysis needs.
3. **Real egress — never a default.** Only as a deliberate, per-sample, logged decision, with egress filtering, rate limiting, and a documented reason. Understand that this is the point at which the operator becomes responsible for what leaves the box.

The VPN discussion below sits *underneath* this policy; it is not a substitute for it. A VPN changes who sees the traffic and where it appears to originate. It does not reduce the harm done to the target, and it does not transfer responsibility.

### Router-Level VPN

A VPN configured only inside a host operating system does not automatically cover every separately booted OS or VM.

```text
ISP
 ↓
VPN router
 ↓
Host / VM / other systems
```

A router-level VPN gives the VPN a broader network scope. It is not inherently necessary for the core containment architecture, and Tails/Tor and a conventional VPN solve different problems — they are not automatically additive.

Note also that a VPN provider will terminate service, and may be legally compelled to act, if malware traffic originates from their exit. Routing analysis traffic through a personal VPN account is a way to lose the account.

## The Output Is Still Hostile

The one-way boundary does **not** make exported data trustworthy.

Anything crossing from the analysis VM into the outer environment should be treated as hostile.

```text
VM
 ↓
malicious ZIP
 ↓
quarantine
 ↓
independent validation / processing (bounded, unprivileged, ideally in a second disposable VM)
 ↓
trusted consumer
```

The outer environment must not assume an artifact is safe merely because it arrived through the authorized channel. Note that the *consumers* are often invisible: desktop file indexers, thumbnailers, antivirus engines, backup agents, and editor language servers will all happily parse a hostile file the moment it lands on disk. Quarantine storage should be excluded from all of them.

## Resource Exhaustion

Containment and resource safety are separate properties. A malicious VM may be unable to escape while still abusing resources it has legitimately been given.

### Example: ZIP bombs

```text
Small compressed file
        ↓
Huge decompressed output
        ↓
Storage exhaustion
```

Other possibilities include:

- CPU exhaustion
- memory exhaustion
- inode/file-count exhaustion
- pathological decompression
- deeply nested archives
- parser vulnerabilities
- malformed files targeting consumers
- automatic indexing or preview systems being attacked
- disk I/O saturation starving the host
- log-volume exhaustion (the monitoring system as the victim)

Therefore the security model must include a **resource envelope**, not just an isolation boundary.

Controls:

- storage quotas (enforced on the *host* side of the channel, not requested politely from the guest)
- maximum output size, enforced by the receiver as it streams
- file-count limits
- CPU limits (cgroups v2 `cpu.max`)
- memory limits (cgroups v2 `memory.max`, with the VMM process included)
- I/O throttling (`io.max`)
- wall-clock execution timeouts with forced destruction
- bounded decompression (ratio *and* absolute output cap *and* nesting depth cap)
- independent, unprivileged processing of exported artifacts

## Anti-Analysis and Evasion

A malware-analysis environment has a problem a pure sandbox does not: **the sample can tell it is being analyzed and change behavior.**

Common detection signals include hypervisor CPUID leaves, virtio/QEMU device identifiers, MAC address OUI ranges, small disk sizes, low RAM, absence of user activity, timing anomalies, and known analysis-tool process names.

This creates a direct tension with the rest of this document:

> Every step taken to *minimize* exposed interfaces makes the VM look *more* obviously like an analysis VM.

Ironveil should resolve this tension explicitly rather than pretending it does not exist. Reasonable position for a research prototype:

- **Containment wins.** Do not weaken isolation to defeat evasion.
- Treat evasion as an *observation*, not a failure: a sample that goes dormant under a hypervisor has told you something useful.
- Cosmetic hardening (realistic disk/RAM sizes, plausible MAC, synthetic user artifacts, uptime skew) is acceptable where it costs no isolation.
- Bare-metal analysis is the real answer to serious evasion, and it is a **different project** with a different boundary.

## Why a VM Still Makes Sense

A VM provides a separate execution environment around potentially hostile workloads. The objective is not necessarily to prevent the guest from being compromised.

```text
Compromise
    ↓
Contained VM
    ↓
Restricted capabilities
    ↓
Limited blast radius
```

Useful for malicious documents, hostile browser content, malware samples, booby-trapped media, untrusted archives, exploit research, and dynamic analysis. The VM can be disposable and recreated between sessions.

### Snapshot and Disposal Hygiene

"Disposable" is a property that has to be enforced, not assumed:

- Boot from a **read-only** base image; all guest writes go to a per-run overlay that is destroyed afterward.
- Destroy means *deleted and the space reclaimed*, not "reverted" — a reverted snapshot chain still holds the malware's data.
- Never reuse an overlay across samples; cross-contamination invalidates every result that follows.
- Guest RAM state, swap, and the VMM's mapped memory are also artifacts — ensure they do not persist to host disk (avoid swapping the VMM; consider locked memory or an encrypted swap the host discards).
- Treat the base image itself as an asset to verify by hash before each run.

## Hardened Outer Environment: Compartmentalization, Not Amnesia

The original sketch called for a "Tails-like" outer environment. This conflated two different properties and should be corrected.

- **Amnesia** (Tails) means nothing persists. It is designed for anonymity under coercion, on hardware the user may not control.
- **Compartmentalization** (Qubes) means different trust domains cannot reach each other. It is designed for containing compromise.

Ironveil needs **compartmentalization**. It does not need amnesia — and amnesia actively fights the requirement, since the entire point of the output channel is to *retain analysis artifacts*.

Tails is additionally a poor host for this work in practice: it is not built to be a hypervisor host, has no persistent storage by design, and running VMs inside it is discouraged upstream. Using it here would be adopting a property that is not wanted while giving up the tooling that is.

The layered model is still correct, with the first layer relabeled:

```text
Compartmentalized / hardened host environment
        +
Virtualization isolation
        +
Kernel / hypervisor enforcement
        +
Restricted I/O
        +
Optional physical one-way hardware
```

These are not "more layers of encryption/privacy." Each layer addresses a different trust problem.

## Interface Minimization

Putting a VM inside a hardened environment changes the trust assumptions: the hypervisor becomes part of the trusted computing base. The more interfaces exposed to the guest, the larger the attack surface:

- shared folders (virtiofs / 9p) — **disabled**
- clipboard sharing — **disabled**
- USB devices / passthrough — **disabled**
- GPU acceleration — **disabled**
- host networking — **disabled by default** (see network policy)
- device passthrough — **disabled**
- audio, serial, balloon, RNG passthrough, and other convenience devices — audited individually

Every enabled interface should require a written justification in the design doc. The default answer is no.

## Hardware vs Software Implementation

### Software mode

```text
Hardened host
    ↓
Kernel / hypervisor enforcement
    ↓
Restricted VM
    ↓
Controlled streaming interface
```

Advantages: easier to prototype, flexible, reproducible, runs on commodity hardware.

Disadvantages: depends on the correctness of the software stack; hypervisor and kernel vulnerabilities remain relevant; cannot make a strong physical one-way guarantee.

### Hardware-assisted mode

```text
Hostile environment
        ↓
Physical one-way mechanism
        ↓
External / trusted environment
```

Advantages: stronger physical separation; directionality no longer depends on software correctness; suitable for high-assurance environments.

Disadvantages: expensive; difficult to engineer, test, and maintain; the hardware itself becomes part of the trusted design.

Note that a hardware diode solves *directionality only*. Output is still hostile, and resource exhaustion still applies — a diode will happily deliver a ZIP bomb at line rate.

## Prototype Roadmap

Do not start by modifying an operating-system kernel.

### Phase 0 — Read First

- Qubes OS architecture specification, and the `qrexec` policy model.
- Decide and document: adopt Qubes, or build on plain Linux with reasons.
- Write the threat model down explicitly: what is trusted, what is not, what is out of scope.

### Phase 1 — Architecture Prototype — **built**

Implemented in this repository; see `README.md` for usage and
`policy/policy.yaml` for the claim-by-claim status. `tests/run-checks` verifies
the configured boundary.

Two deviations from the sketch below, both deliberate:

- **Direct QEMU rather than libvirt.** No root daemon is introduced into the
  trusted computing base, and the launcher's argument list is a single
  auditable statement of the guest's entire hardware surface. sVirt is replaced
  by a named AppArmor profile applied via `aa-exec`.
- **No scratch disk.** The guest is RAM-only: kernel plus initramfs, no block
  device at all. This makes base-image immutability structural rather than
  procedural. A scratch disk would require `virtio_blk`, which is a module in
  the Alpine virt kernel, and would reintroduce a device class currently at
  zero.

Concretely:

- libvirt + QEMU/KVM
- QEMU running as an **unprivileged** user, under seccomp, confined by sVirt (SELinux or AppArmor)
- **no** virtiofs/9p, **no** clipboard, **no** USB, **no** GPU, **no** device passthrough
- **no** NIC (or an isolated network with INetSim once network-dependent samples are in scope)
- read-only base image + per-run overlay, destroyed after each run
- cgroups v2 limits: `cpu.max`, `memory.max`, `io.max`, plus pids limit
- wall-clock timeout with forced domain destruction
- output via **vsock**, length-prefixed frames, to an unprivileged host receiver enforcing size/count caps
- quarantine directory with a filesystem quota, excluded from indexers, thumbnailers, AV, and backups
- ingest tooling with bounded decompression (ratio cap, absolute cap, depth cap)

### Phase 2 — Adversarial Testing

Build deliberately hostile test workloads (synthetic, not live malware, at this stage). Attempt to violate policy through:

- filesystem access attempts
- device interfaces and `ioctl` surfaces
- memory mappings and DMA
- virtualization / paravirtual channels
- resource exhaustion in every dimension listed above
- malformed output aimed at the receiver and the ingest tooling
- unexpected I/O paths
- attempts to signal backward through the output channel (measure the actual reverse bandwidth rather than assuming it is zero)

Each test should assert against a written policy statement, so a pass means something specific.

### Phase 3 — Stronger Enforcement

Move critical restrictions below the guest: host kernel, hypervisor/VMM, I/O mediation, device isolation. The goal is to make the security property independent of guest cooperation.

### Phase 4 — Hardware Boundary

If the software model is sound, investigate a physical one-way transfer mechanism, as an *additional* assurance layer rather than a replacement for careful software isolation.

## Research Questions

1. What exactly is the trusted computing base?
2. Which components remain trusted if the guest kernel is compromised?
3. What are all possible paths from guest to host?
4. What are all possible paths from host to guest?
5. Which capabilities does the VM actually need?
6. Can the guest obtain information through unintended side channels?
7. What is the *measured* reverse bandwidth of the output channel?
8. Can exported data attack the outer system — including its invisible consumers (indexers, AV, backup)?
9. What happens when output storage is exhausted?
10. What happens when CPU or memory resources are exhausted?
11. Can the hypervisor or virtual device model be attacked?
12. Which guarantees require hardware rather than software?
13. How can the security properties be tested independently?
14. What does Qubes already solve here, and what is genuinely left over?
15. How is evasion distinguished from successful containment in the results?
16. What is the operator's responsibility for traffic that leaves the box?

## Design Philosophy

> **Do not make the hostile environment trustworthy. Make trust unnecessary.**

Rather than asking:

> "How do we stop the malware from being malicious?"

ask:

> "What is the worst thing the malware can do with the capabilities we have given it?"

That question should drive the architecture.

## Naming

Candidates considered: Ironveil, Unidome, Glasshouse, Airlock, Deadbolt, Blackbox, Cordon, Ironbox, Vaultline, Nullgate, Redoubt, Sentinel.

**Preferred: Ironveil** — a hardened boundary around something dangerous.

## Scope and Safety

This project is a security-engineering and systems-research exercise.

The initial goal is to demonstrate and test the isolation model using **controlled and synthetic adversarial workloads**, not to immediately build a production-grade malware-analysis platform. Live malware should not be introduced until Phase 2 has actually demonstrated the boundary holds against synthetic attacks, and not on hardware or a network that matters.

The most valuable outcome is not a working sandbox. It is a clearly defined, explicitly stated, and experimentally tested **security boundary** — including an honest account of what it does *not* guarantee.

## References

Links verified 2026-08-24.

### Qubes OS — primary prior art

| Resource | Why it matters here |
| --- | --- |
| [Architecture overview](https://www.qubes-os.org/doc/architecture/) | The compartmentalization model in summary form. |
| [Architecture specification (PDF, v0.3)](https://www.qubes-os.org/attachment/doc/arch-spec-0.3.pdf) | The original design document. Predates the current codebase, but explains the *reasoning* behind each boundary — which is the part worth borrowing. |
| [Security goals and threat model](https://www.qubes-os.org/security/goals/) | A worked example of stating what a system explicitly does **not** guarantee. Compare against Ironveil's own threat model before Phase 1. |
| [qrexec](https://www.qubes-os.org/doc/qrexec/) | Policy-mediated inter-VM RPC. This is a hardened, deployed version of Ironveil's narrow output channel; the policy file format is the interesting part. |
| [Disposable VMs](https://www.qubes-os.org/doc/disposable/) | Their implementation of the disposable analysis VM and its lifecycle. |
| [Copying files between qubes](https://www.qubes-os.org/doc/how-to-copy-and-move-files/) | Note that the *receiving* domain initiates the transfer and no filesystem is ever mounted across the boundary — the same conclusion reached in "Do Not Mount Guest-Authored Filesystems" above. |
| [Device handling security](https://www.qubes-os.org/doc/device-handling-security/) | USB / PCI / storage attack surface; maps onto the Interface Minimization section. |
| [Firewall and networking](https://www.qubes-os.org/doc/firewall/) | Per-domain network isolation via NetVM / ProxyVM. |
| [Documentation index](https://www.qubes-os.org/doc/) | Everything else. |
| [Downloads](https://www.qubes-os.org/downloads/) | Hardware support is narrow — check the HCL before committing a machine, particularly for wifi and GPUs. |

### Other prior art

Referenced in the Prior Art section above; retained here for convenience.

- **CAPE / Cuckoo Sandbox** — automated dynamic-analysis platforms. Relevant for instrumentation and evasion handling rather than isolation.
- **INetSim / FakeNet-NG** — simulated internet services for network-dependent samples.
- **sVirt (libvirt + SELinux/AppArmor)** — mandatory access control confinement of the VMM process itself.
- **Data diode literature** — for the distinction between *directional* and genuinely *one-way*.
