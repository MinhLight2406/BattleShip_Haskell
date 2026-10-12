FROM battleship-regression:nm08 AS built
RUN install -D "$(stack path --local-install-root)/bin/battleship-server" /out/battleship-server
FROM battleship-haskell:local
COPY --from=built /out/battleship-server /usr/local/bin/battleship-server
