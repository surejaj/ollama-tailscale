FROM ollama/ollama:latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates nginx-light \
    && curl -fsSL https://tailscale.com/install.sh | sh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
