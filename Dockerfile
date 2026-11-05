FROM denoland/deno:alpine-2.9.8

RUN apk add --no-cache jq curl apprise

WORKDIR /app

COPY deno.json deno.lock ./

COPY * ./

RUN chmod +x *.sh

RUN deno cache --lock=deno.lock main.ts

ENTRYPOINT ["/app/entrypoint.sh"]
