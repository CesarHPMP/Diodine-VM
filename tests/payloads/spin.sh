#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 César Henrique Policarpo de Melo
# RES-005: never terminate. The host's wall-clock deadline must destroy this
# VM without any cooperation from the guest.
set -u
echo "spinning" > /diodine/out/started.txt
while :; do :; done
