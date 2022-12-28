FROM bash:5

WORKDIR /app
COPY . .

ENV CONFIG_DIR=/app/config STORE_DIR=/backup

RUN apk update \
    && apk add gawk pv pigz
