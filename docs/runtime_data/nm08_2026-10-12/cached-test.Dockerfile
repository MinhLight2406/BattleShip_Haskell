FROM battleship-haskell-test:dk04
WORKDIR /build
COPY . .
RUN stack build --system-ghc --no-install-ghc
