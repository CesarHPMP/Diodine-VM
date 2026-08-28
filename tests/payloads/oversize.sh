#!/bin/sh
# RES-006: emit an artifact far larger than the per-artifact cap the harness
# passes. The receiver must cut the stream off mid-write and remove the
# partial file rather than letting it land.
set -u
dd if=/dev/zero of=/diodine/out/huge.bin bs=1024 count=512 2>/dev/null
