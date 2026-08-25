#!/bin/sh
# RES-005: never terminate. The host's wall-clock deadline must destroy this
# VM without any cooperation from the guest.
set -u
echo "spinning" > /ironveil/out/started.txt
while :; do :; done
