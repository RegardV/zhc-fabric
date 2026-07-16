# zhc-fabric Phase 3 OTP sidecar. Stdlib only (inets/httpc/json) — no hex deps.
FROM erlang:27-alpine

WORKDIR /app
COPY src/ src/
RUN mkdir -p ebin \
 && erlc -o ebin src/*.erl \
 && cp src/zhc_fabric.app.src ebin/zhc_fabric.app

ENV FABRIC_HOST=0.0.0.0 \
    FABRIC_PORT=7733
EXPOSE 7733

CMD ["erl", "-noinput", "-pa", "ebin", "-s", "zhc_fabric_app", "boot"]
