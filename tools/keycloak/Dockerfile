# Supply version tags or digests that match the work environment; no latest defaults.
ARG KEYCLOAK_IMAGE
ARG CONFIG_CLI_IMAGE
FROM ${KEYCLOAK_IMAGE} AS keycloak
FROM ${CONFIG_CLI_IMAGE}

USER 0
COPY --from=keycloak --chown=65534:65534 /opt/keycloak /opt/keycloak
COPY --chmod=755 keycloak.sh /usr/local/bin/keycloak-tool
RUN test -f /app/keycloak-config-cli.jar && test -x /opt/keycloak/bin/kcadm.sh
ENV HOME=/tmp JAVA_OPTS=""
WORKDIR /tmp
USER 65534:65534
ENTRYPOINT ["/usr/local/bin/keycloak-tool"]
CMD ["help"]
