#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 César Henrique Policarpo de Melo
# AUD-002: try to collide with every host-authored record in the run directory.
# Each of these names passes the receiver's name validation -- the defence has
# to be that they land in a namespace the host's own records do not share.
for n in MANIFEST.json RUN.json console.log RUN.json.writing RUN.json.denials vmm.log; do
    echo "FORGED BY THE GUEST" > "/diodine/out/$n"
done
echo "genuine artifact" > /diodine/out/genuine.txt
