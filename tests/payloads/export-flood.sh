#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 César Henrique Policarpo de Melo
# RES-006: exceed the total-bytes cap and the artifact-count cap.
#
# tests/payloads/oversize.sh already attacks the PER-FILE cap with one big
# artifact. This attacks the other two bounds, which a single oversized file
# never reaches: many small artifacts whose sum crosses --max-total, and more
# artifacts than --max-files allows.
set -u
i=0
while [ "$i" -lt 40 ]; do
    dd if=/dev/zero of="/diodine/out/blob.$i" bs=1024 count=64 2>/dev/null || break
    i=$((i + 1))
done
