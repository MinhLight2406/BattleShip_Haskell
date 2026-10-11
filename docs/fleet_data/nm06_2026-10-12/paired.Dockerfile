# Measurement only; no production service depends on this image.
FROM battleship-benchmark:nm06
COPY --from=battleship-fleet-before:nm06 /usr/local/bin/battleship-benchmark /usr/local/bin/battleship-benchmark-before
