FROM eclipse-temurin:17-jre-alpine

LABEL maintainer="Aito <support@aito.ai>" \
      description="Aito - the predictive database. Free for development, licensed for production." \
      org.opencontainers.image.source="https://github.com/aitohq/aito" \
      org.opencontainers.image.documentation="https://aito.ai/docs" \
      org.opencontainers.image.vendor="aito.ai"

# bash (entrypoint), curl + jq (license validation),
# openssl (encrypts the cached validation response on disk).
RUN apk add --no-cache bash curl jq openssl && \
    addgroup -g 1000 aito && \
    adduser -u 1000 -G aito -D aito && \
    mkdir -p /io/state && \
    chown -R aito:aito /io

# JAR is downloaded from the matching AitoDotAI/aito-core release by
# the publish workflow and placed in the build context as aitoai-free.jar.
COPY aitoai-free.jar /opt/aitoai/aitoai.jar
COPY scripts/entrypoint.sh /opt/aitoai/entrypoint.sh
COPY scripts/validate-license.sh /opt/aitoai/validate-license.sh
RUN chmod +x /opt/aitoai/entrypoint.sh /opt/aitoai/validate-license.sh

ENV PORT=9005 \
    BIND_ADDRESS=0.0.0.0 \
    STATE_PATH=/io/state \
    KEY_VALIDATION=DISABLED \
    DISABLE_API_KEY_AUTH=true \
    DISABLE_WRITE_API_KEY_AUTH=true

EXPOSE 9005
VOLUME ["/io/state"]

USER aito

ENTRYPOINT ["/opt/aitoai/entrypoint.sh"]
