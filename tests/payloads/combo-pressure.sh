#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 César Henrique Policarpo de Melo
# RES-001 + RES-006 + RES-007 at once.
#
# NEXT.md asks for the caps "in combination -- memory pressure *while* streaming
# at the export cap *while* flooding the console", because caps that each hold
# alone can still interact: the console writer and the artifact writer are
# different host paths, and memory pressure changes the timing of both.
set -u
echo "combo" > /diodine/out/started.txt

# See mem-bomb.sh: a default tmpfs is half of RAM and never reaches the cap.
mkdir -p /pressure 2>/dev/null
mount -t tmpfs -o size=4096M tmpfs /pressure 2>/dev/null || true
DIR=/pressure
[ -w "$DIR" ] || DIR=/

# Console flood, backgrounded.
( i=0; while [ "$i" -lt 400 ]; do
    echo "CONSOLE-PRESSURE-$i-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" > /dev/console
    i=$((i + 1)); done ) &

# Memory pressure, backgrounded.
( i=0; while [ "$i" -lt 12 ]; do
    dd if=/dev/zero of="$DIR/ballast.$i" bs=1M count=64 2>/dev/null || break
    i=$((i + 1)); done ) &

# Export pressure in the foreground.
i=0
while [ "$i" -lt 20 ]; do
    dd if=/dev/zero of="/diodine/out/blob.$i" bs=1024 count=64 2>/dev/null || break
    i=$((i + 1))
done
wait
