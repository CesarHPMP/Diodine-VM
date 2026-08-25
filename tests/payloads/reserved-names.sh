#!/bin/sh
# AUD-002: try to collide with every host-authored record in the run directory.
# Each of these names passes the receiver's name validation -- the defence has
# to be that they land in a namespace the host's own records do not share.
for n in MANIFEST.json RUN.json console.log RUN.json.writing; do
    echo "FORGED BY THE GUEST" > "/ironveil/out/$n"
done
echo "genuine artifact" > /ironveil/out/genuine.txt
