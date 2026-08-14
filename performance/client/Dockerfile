# syntax=docker/dockerfile:1.7
# Base images use version tags. Publish a new validation-client tag whenever a
# base-image version changes.
ARG BUILD_IMAGE=maven:3.9.16-eclipse-temurin-17
FROM ${BUILD_IMAGE} AS build

WORKDIR /src
COPY pom.xml .
RUN mvn -B -ntp dependency:go-offline
COPY src ./src
RUN mvn -B -ntp -DskipTests package

ARG RUNTIME_IMAGE=eclipse-temurin:17-jre
FROM ${RUNTIME_IMAGE}

LABEL org.opencontainers.image.title="Artemis deterministic validation client" \
      org.opencontainers.image.description="OpenWire and AMQP durable-message validation client" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="repository-owned validation client"

WORKDIR /opt/validation-client
COPY --from=build /src/target/deterministic-validation-client-*.jar /opt/validation-client/client.jar
COPY --from=build /src/target/lib /opt/validation-client/lib

USER 65532:65532
ENV JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=/tmp"
ENTRYPOINT ["java", "-cp", "/opt/validation-client/client.jar:/opt/validation-client/lib/*", "org.example.artemis.validation.Main"]
