FROM battleship-haskell:local
USER root
RUN apt-get update && apt-get install -y --no-install-recommends numactl && rm -rf /var/lib/apt/lists/*
COPY docker/numa-entrypoint.sh /usr/local/bin/battleship-numa-entrypoint
RUN sed -i 's/\r$//' /usr/local/bin/battleship-numa-entrypoint && chmod 0555 /usr/local/bin/battleship-numa-entrypoint
USER 10001:10001