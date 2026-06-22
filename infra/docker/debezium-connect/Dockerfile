FROM quay.io/debezium/connect:2.7.3.Final AS debezium
FROM quay.io/strimzi/kafka:0.41.0-kafka-3.7.0
USER root:root
RUN mkdir -p /opt/kafka/plugins/debezium-connector-postgres
COPY --from=debezium /kafka/connect/debezium-connector-postgres/ /opt/kafka/plugins/debezium-connector-postgres/
USER 1001
