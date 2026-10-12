# Re-measure historical game source; not an exact archived NM-03 harness/image.
ARG BENCH_COMPILER=battleship-haskell-test:current
ARG BENCH_WEB=battleship-web:local
FROM ${BENCH_COMPILER} AS build
WORKDIR /reproduce
COPY . .
RUN test "$(ghc --numeric-version)" = 9.10.3 \
    && stack build --bench --no-run-benchmarks --system-ghc --no-install-ghc --ghc-options="-O2 -Werror" \
    && install -D "$(stack path --dist-dir)/build/battleship-benchmark/battleship-benchmark" /out/battleship-benchmark \
    && install -D "$(stack path --local-install-root)/bin/battleship-server" /out/battleship-server \
    && sha256sum bench/*.hs src/Battleship/*.hs src/Battleship/Internal/*.hs app/*.hs test/TestSupport/Generators.hs package.yaml stack.yaml > /out/build-source-sha256.txt
FROM ${BENCH_WEB}
USER root
COPY --from=build /out/ /usr/local/bin/
COPY --from=build /usr/lib/x86_64-linux-gnu/libgmp.so.10 /usr/lib/x86_64-linux-gnu/libgmp.so.10
COPY frontend/bridge.mjs /app/bridge.mjs
RUN ldd /usr/local/bin/battleship-benchmark | tee /tmp/baseline-ldd \
    && ! grep -q 'not found' /tmp/baseline-ldd
USER node
WORKDIR /probe
HEALTHCHECK NONE
ENTRYPOINT ["node", "/probe/scripts/remeasure-baseline.mjs", "--baseline"]
