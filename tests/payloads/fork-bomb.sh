#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 César Henrique Policarpo de Melo
# RES-003: fork hard inside the guest.
#
# This attacks the CLAIM more than the mechanism. TasksMax is set on the host
# cgroup, which contains QEMU's threads -- not the guest's processes, which live
# inside the guest kernel and are invisible to it. If "guest process count is
# capped" were true as written, this payload would be stopped by that cap. The
# suite records what actually bounds it.
set -u
echo "fork-bomb" > /diodine/out/started.txt
i=0
while [ "$i" -lt 300 ]; do
    (sleep 45) &
    i=$((i + 1))
done
# Count what the guest kernel actually let us have.
ps 2>/dev/null | wc -l > /diodine/out/guest_procs.txt 2>/dev/null || true
echo "$i" > /diodine/out/forks_attempted.txt 2>/dev/null || true
sleep 3
