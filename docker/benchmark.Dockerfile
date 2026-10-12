# Experimental test image; neither production Compose service uses this file.
ARG HASKELL_BENCH_BASE=battleship-haskell-test:dk04
ARG WEB_BENCH_BASE=battleship-web:local
FROM ${HASKELL_BENCH_BASE} AS build
WORKDIR /build
COPY . .
RUN test "$(ghc --numeric-version)" = 9.10.3 \
    && stack build --bench --no-run-benchmarks --system-ghc --no-install-ghc --ghc-options="-O2 -Werror" \
    && install -D "$(stack path --dist-dir)/build/battleship-benchmark/battleship-benchmark" /out/battleship-benchmark \
    && install -D "$(stack path --dist-dir)/build/battleship-fleet-benchmark/battleship-fleet-benchmark" /out/battleship-fleet-benchmark \
    && install -D "$(stack path --local-install-root)/bin/battleship-server" /out/battleship-server \
    && sha256sum bench/*.hs src/Battleship/*.hs src/Battleship/Internal/*.hs app/*.hs test/TestSupport/Generators.hs package.yaml stack.yaml > /out/build-source-sha256.txt

FROM ${WEB_BENCH_BASE} AS runtime
USER root
RUN apt-get update && apt-get install -y --no-install-recommends numactl libnuma1 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/ /usr/local/bin/
COPY docker/numa-entrypoint.sh /usr/local/bin/battleship-numa-entrypoint
RUN sed -i 's/\r$//' /usr/local/bin/battleship-numa-entrypoint && chmod 0555 /usr/local/bin/battleship-numa-entrypoint
COPY --from=build /usr/lib/x86_64-linux-gnu/libgmp.so.10 /usr/lib/x86_64-linux-gnu/libgmp.so.10
RUN ldd /usr/local/bin/battleship-benchmark | tee /tmp/bench-ldd \
    && ! grep -q 'not found' /tmp/bench-ldd
USER node
WORKDIR /probe
HEALTHCHECK NONE
ENTRYPOINT ["node", "/probe/scripts/benchmark-runtime.mjs"]
