# Same pinned Node/Debian runtime for dependency installation, tests and serving.
FROM node:24.21.0-bookworm-slim@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20 AS node

FROM node AS toolchain
RUN test "$(node --version)" = v24.21.0 \
    && npm install --global pnpm@11.25.0 \
    && test "$(pnpm --version)" = 11.25.0
WORKDIR /build/frontend
COPY frontend/package.json frontend/pnpm-lock.yaml ./

FROM toolchain AS production
RUN pnpm install --prod --frozen-lockfile

FROM toolchain AS test
RUN pnpm install --frozen-lockfile
COPY frontend/ ./
# Contract tests read these root-level artifacts relative to frontend/test.
COPY .env.example /build/.env.example
COPY docs/ /build/docs/
RUN pnpm build && pnpm test
CMD ["pnpm", "test"]

FROM node AS runtime
ENV NODE_ENV=production \
    HOST=0.0.0.0 PORT=8080 WEB_PUBLIC_PORT=8081 \
    PUBLIC_ORIGIN=http://localhost:8081 \
    BATTLESHIP_TCP_HOST=haskell BATTLESHIP_TCP_PORT=4000
WORKDIR /app
# Taking output from test prevents the runtime target from bypassing its gate.
COPY --from=test /build/frontend/dist ./dist
COPY --from=test /build/frontend/bridge.mjs ./bridge.mjs
COPY --from=production /build/frontend/node_modules ./node_modules
USER node
EXPOSE 8080
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=2s --timeout=1s --start-period=10s --retries=5 \
    CMD ["node", "--input-type=module", "-e", "const r = await fetch('http://127.0.0.1:' + process.env.PORT + '/healthz', {signal: AbortSignal.timeout(800)}); if (!r.ok || (await r.json()).status !== 'ok') process.exit(1)"]
ENTRYPOINT ["node", "bridge.mjs"]
CMD []
