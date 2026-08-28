/* OUT-002 measurement probe -- guest side.
 *
 * The reverse channel exists because the host's drain rate is observable from
 * inside the guest. When the host stops reading, the 64KB FIFO fills, QEMU
 * stops draining the virtqueue, and the guest's write() blocks. Blocking is
 * timing, and timing is information. This measures how much.
 *
 * Method: emit one large DVF1 frame as a carrier -- the bytes are meaningless,
 * the point is to keep writing -- and record how long each chunk's write() took.
 * Then emit the latency series as a second frame. The host correlates that
 * series against the signal schedule it transmitted.
 *
 * Two constraints shaped this:
 *
 *   - A shell cannot do it. Busybox date silently ignores %N (it returns bare
 *     epoch seconds) and /proc/uptime is 10ms. Measuring the channel with a
 *     10ms clock would understate it badly. A real sample is a compiled binary
 *     with clock_gettime, so measuring with one is also the honest threat model.
 *
 *   - The carrier must be valid framing. Raw bytes at the port fail the
 *     receiver's magic check and abort the stream, so the carrier has to be a
 *     legitimate artifact that happens to be large.
 *
 * Built static on the host and passed as --payload. Deliberately NOT in the
 * base image: the guest's standard userland should stay minimal, and a
 * measurement tool is not part of the boundary.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>

#define PORT    "/dev/virtio-ports/org.diodine.out"
#define CHUNK   4096
/* Unpaced, the channel absorbs ~350 MB/s, so any carrier small enough to fit
 * under RES-006 drains in well under a second -- 32 MiB went in 0.09s. To hold
 * the channel open long enough to carry a pattern at all, the guest has to slow
 * itself down. PACE_US is that self-throttle.
 *
 * This is the interesting part of the result, not an implementation detail. The
 * guest faces a trade-off it cannot escape:
 *
 *   write fast  -> the 64KB FIFO fills in ~160us, so a stall is detectable
 *                  almost immediately (high bitrate) -- but the export cap is
 *                  reached in under a second, so the channel closes.
 *   write slow  -> the channel stays open for the whole run, but the FIFO now
 *                  takes PACE_US * 16 to fill, and nothing is detectable faster
 *                  than that (low bitrate).
 *
 * So RES-006's byte cap is also a bound on this covert channel's duration, and
 * the buffer depth is a bound on its symbol rate. Neither was designed for that.
 */
/* 48 MiB was not enough: with the reader stopped for the whole window the guest
 * wrote all of it and never blocked once, so the buffer between write() and
 * read() is larger than that. To find the depth the guest has to be able to
 * out-write any plausible buffer, hence 512 MiB. */
#define CARRIER (512u * 1024u * 1024u)
#define PACE_US 0
#define NSAMP   (CARRIER / CHUNK)

static int write_all(int fd, const void *p, size_t n)
{
    const char *b = p;
    while (n) {
        ssize_t w = write(fd, b, n);
        if (w < 0) return -1;
        b += w; n -= (size_t)w;
    }
    return 0;
}

/* DVF1 | uint16 name_len | uint64 size | name -- big endian, no padding. */
static int emit_header(int fd, const char *name, uint64_t size)
{
    uint8_t h[14];
    uint16_t nl = (uint16_t)strlen(name);
    memcpy(h, "DVF1", 4);
    h[4] = (uint8_t)(nl >> 8);
    h[5] = (uint8_t)nl;
    for (int i = 0; i < 8; i++) h[6 + i] = (uint8_t)(size >> (56 - 8 * i));
    if (write_all(fd, h, sizeof h) < 0) return -1;
    return write_all(fd, name, nl);
}

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

int main(void)
{
    static uint32_t lat_us[NSAMP];
    static uint32_t off_us[NSAMP];
    static char buf[CHUNK];
    memset(buf, 'C', sizeof buf);

    int fd = open(PORT, O_WRONLY);
    if (fd < 0) { perror("open port"); return 1; }

    if (emit_header(fd, "carrier.bin", CARRIER) < 0) { perror("header"); return 1; }

    uint64_t t0 = now_ns();
    for (unsigned i = 0; i < NSAMP; i++) {
        uint64_t a = now_ns();
        if (write_all(fd, buf, CHUNK) < 0) { perror("carrier write"); return 1; }
        uint64_t b = now_ns();
        lat_us[i] = (uint32_t)((b - a) / 1000);
        off_us[i] = (uint32_t)((a - t0) / 1000);

        /* Self-throttle. Only write() is timed above, so the pacing sleep does
         * not inflate the latency measurement -- it only decides how long the
         * carrier lasts and how quickly the FIFO can fill. */
        struct timespec pace = { 0, PACE_US * 1000L };
        nanosleep(&pace, NULL);
    }

    size_t cap = (size_t)NSAMP * 24 + 64, used = 0;
    char *out = malloc(cap);
    if (!out) { perror("malloc"); return 1; }
    used += (size_t)snprintf(out + used, cap - used, "# t_us lat_us\n");
    for (unsigned i = 0; i < NSAMP; i++)
        used += (size_t)snprintf(out + used, cap - used, "%u %u\n",
                                 off_us[i], lat_us[i]);

    if (emit_header(fd, "latency.txt", used) < 0) { perror("header2"); return 1; }
    if (write_all(fd, out, used) < 0) { perror("series write"); return 1; }
    close(fd);
    return 0;
}
