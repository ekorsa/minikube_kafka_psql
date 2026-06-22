# minikube_kafka_psql

Учебный стенд: PostgreSQL (CNPG) → Debezium CDC → Kafka (Strimzi).

Управление стендом — через `./stand.sh`. Подробная документация по чартам: [`infra/README.md`](infra/README.md).

## Траблшутинг: чтение логов Kafka

### Порядок диагностики

1. `kubectl get pods -n kafka` — есть ли CrashLoop / не-Ready
2. `kubectl get events -n kafka --sort-by='.lastTimestamp' | tail -20` — что произошло
3. Если проблема в коннекторе — смотреть статус CR (см. ниже)
4. Если проблема в брокере — `kubectl logs` с grep на ERROR/FATAL
5. `kubectl describe pod <pod>` — если под не стартует (OOM, ImagePullBackOff)

### Kafka broker

```bash
# Живой поток
kubectl logs -n kafka kafka-cluster-kafka-0 -c kafka -f

# Только ошибки (убрать JVM-шум)
kubectl logs -n kafka kafka-cluster-kafka-0 -c kafka | grep -iE "ERROR|FATAL|Exception"

# Последние 100 строк
kubectl logs -n kafka kafka-cluster-kafka-0 -c kafka --tail=100
```

### Debezium / KafkaConnect

```bash
# Живой поток, только проблемы
kubectl logs -n kafka debezium-connect-connect-0 -f | grep -iE "ERROR|WARN|FATAL|Exception"

# Статус коннектора и стектрейс последней ошибки задачи
kubectl get kafkaconnector debezium-outbox-connector -n kafka \
  -o jsonpath='{.status.connectorStatus.tasks[0].trace}'
```

### Zookeeper

```bash
kubectl logs -n kafka kafka-cluster-zookeeper-0 -c zookeeper --tail=50
```

### Entity Operator (управляет KafkaTopic CR)

```bash
kubectl logs -n kafka deploy/kafka-cluster-entity-operator -c topic-operator --tail=50
```

### События кластера

```bash
kubectl get events -n kafka --sort-by='.lastTimestamp' | tail -20
kubectl get events -n postgres --sort-by='.lastTimestamp' | tail -20
```
