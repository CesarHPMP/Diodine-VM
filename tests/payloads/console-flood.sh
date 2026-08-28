#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 César Henrique Policarpo de Melo
# RES-007: write to the host-backed console as fast as the guest can.
# The console bypasses the receiver entirely, so none of the export caps apply
# to it. What bounds it is the emulated UART's throughput and the wall clock.
dd if=/dev/zero of=/dev/console bs=65536 2>/dev/null
