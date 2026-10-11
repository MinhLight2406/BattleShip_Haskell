FROM battleship-haskell-test:dk04 AS test
WORKDIR /build
COPY . .
RUN stack build --system-ghc --no-install-ghc --ghc-options=-Werror && stack test --system-ghc --no-install-ghc --ghc-options=-Werror && install -D "$(stack path --local-install-root)/bin/battleship-server" /out/battleship-server
FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587 AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends libgmp10 libnuma1 libffi8 libtinfo6 zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 battleship \
    && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin battleship

# Depending on test makes the runtime build fail if the Linux suite fails.
COPY --from=test /out/battleship-server /usr/local/bin/battleship-server
RUN ldd /usr/local/bin/battleship-server > /tmp/battleship-ldd \
    && cat /tmp/battleship-ldd \
    && ! grep -q 'not found' /tmp/battleship-ldd \
    && rm /tmp/battleship-ldd

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    BATTLESHIP_BIND_HOST=0.0.0.0 \
    BATTLESHIP_READY_FILE=/tmp/battleship-ready
WORKDIR /app
USER 10001:10001
EXPOSE 4000
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=2s --timeout=1s --start-period=10s --retries=5 \
    CMD ["sh", "-ec", "test \"$(cat \"$BATTLESHIP_READY_FILE\")\" = ready"]
ENTRYPOINT ["/usr/local/bin/battleship-server"]
CMD ["4000"]
