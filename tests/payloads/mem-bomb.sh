#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 César Henrique Policarpo de Melo
# RES-001: touch every page the guest was given, and keep going past it.
#
# The guest's root filesystem IS its RAM -- the initramfs is a tmpfs -- so
# writing files is the most direct way for an unprivileged-looking payload to
# make QEMU fault in every page it was allocated. Demand paging means the host
# only commits what the guest actually touches, so a guest that merely *has*
# 1 GiB costs far less until it writes to it. This writes to it.
set -u
echo "mem-bomb" > /diodine/out/started.txt

# A tmpfs defaults to HALF of RAM, so writing into / stalls around 512 MiB on a
# 1 GiB guest and the host's own cap is never approached -- the first version of
# this payload peaked at 612 MiB against a 1024 MiB limit and proved nothing
# about the limit. Mount one sized ABOVE guest RAM so the guest kernel, not the
# filesystem, is what eventually says no.
mkdir -p /pressure 2>/dev/null
mount -t tmpfs -o size=4096M tmpfs /pressure 2>/dev/null || true
DIR=/pressure
[ -w "$DIR" ] || DIR=/

i=0
# Deliberately past the guest's own RAM: the interesting question is what the
# HOST does when the guest asks for more than it was given, not whether the
# guest can count.
while [ "$i" -lt 40 ]; do
    dd if=/dev/zero of="$DIR/ballast.$i" bs=1M count=64 2>/dev/null || break
    i=$((i + 1))
done
echo "$((i * 64))" > /diodine/out/allocated_mib.txt 2>/dev/null || true
