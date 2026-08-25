# OUT-002 — measuring the reverse channel

`OUT-002` says the output channel is directional but not one-way: the host's
drain rate is observable from inside the guest, because when the host stops
reading, the buffer between them fills and the guest's `write()` blocks.
Blocking is timing, and timing is information.

This directory measures how much. Nothing here is part of the boundary — it is
test tooling, and the compiled `probe` is a build artifact, not committed.

## Result

    buffer depth        585728 bytes (0.56 MiB), identical across runs
    detection floor     ~8 ms — the time to refill that buffer at ~73 MB/s
    long-stall fidelity 19.02 s measured against 20.00 s commanded
    short pulses        10/20/50 ms all read back 15–32 ms, ±5–11 ms
    per-run capacity    ~450 symbols — byte-capped by RES-006, not time-capped

The binding limit is `RES-006`. Each symbol the guest can read costs it ~0.56 MiB
of export budget, because the buffer has to refill before another stall is
detectable. At the default 256 MB total cap that is on the order of 450
detections per run, whatever the symbol rate. **Raising `--max-total` raises this
channel's capacity proportionally.**

Short pulses are noisy for a reason worth understanding: at full write speed the
receiver cannot keep up — it hashes and writes to disk — so it stalls on its own,
producing blocking writes of the same magnitude as the signal. The channel is
self-noisy at the rate that would make it fast, and writing slower to quiet the
noise enlarges the refill time. The guest cannot have both.

## Reproducing

    gcc -static -O2 -Wall -o tests/out002/probe tests/out002/probe.c

Buffer depth and long-stall fidelity:

    ./bin/ironveil-run --payload tests/out002/probe --timeout 90 \
        --max-artifact 1073741824 --max-total 2147483648 &
    ./tests/out002/modulate --pulses 20000 --repeat 1 --gap-ms 10 --out /tmp/s.txt

Then read `latency.txt` from the run's `artifacts/`: the first blocking write's
sample index times 4096 is the buffer depth, and its duration is the stall the
guest recovered.

Detection floor, one duration per run:

    ./tests/out002/modulate --pulses 20 --repeat 8 --gap-ms 200 --out /tmp/s20.txt
    ./tests/out002/analyse-pulses --schedule /tmp/s20.txt \
        --latency quarantine/<run>/artifacts/latency.txt

## Two ways this measurement lied before the instrument was fixed

**The modulator stopped the wrong process.** Matching the receiver by command
line found the pyenv shim — `bash pyenv-exec python3 .../ironveil-receiver` —
whose argv contains the receiver's path while the process doing the reading is
its child. `SIGSTOP` on the wrapper stops nothing. The reader kept draining and
every arm built on it reported *no backpressure at all*, up to 512 MB, which
looked like a clean and interesting result. `modulate` now finds the reader by
which process holds `iv.out` open — descriptor ownership, the same argument
`OUT-001` itself rests on.

Validate the instrument before trusting a number from it:

    # while stopped, state must be T and the artifact must not grow
    awk '{print $3}' /proc/<pid>/stat
    stat -c %s quarantine/<run>/artifacts/carrier.bin

**The analyser paired events in order.** With 22 observed events for 25
commanded pulses, one miss shifts every later pair, and a 100 ms stall reads as
39 ms. One duration per run removes the ambiguity. `analyse-pulses` also
requires n≥3 before calling a duration resolved — its first version declared a
10 ms pulse "cleanly resolved" from a single sample that was off by +35 ms,
because with one sample the spread is 0 by construction and the check could not
fail.

## Why the carrier looks the way it does

The probe emits a large `IVF1` frame and uses that stream as the carrier. Raw
bytes at the port would fail the receiver's magic check and abort the stream, so
the carrier has to be a legitimate artifact that happens to be big.

The probe is a static binary because a shell cannot do this: busybox `date`
silently ignores `%N` and returns bare epoch seconds, and `/proc/uptime` is 10 ms.
Measuring an 8 ms floor with a 10 ms clock would understate the channel. It is
also the honest threat model — a real sample is compiled code with
`clock_gettime`.
