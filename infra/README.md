# Kafka + PostgreSQL Outbox + Monitoring — Kubernetes Stand

Стенд для изучения Kafka: от базовой публикации событий через паттерн Outbox до мониторинга consumer lag и экспериментов с отказом брокеров.

## Архитектура

```
PostgreSQL (CNPG)          Strimzi Kafka
  └── outbox table  ──▶  KafkaConnect (Debezium)  ──▶  kafka-cluster
       (WAL/CDC)              Outbox Event Router           │
                                                        KafkaTopic
                                                    outbox.events.orders

Prometheus ◀── PodMonitor ──── JMX Exporter (Kafka, KafkaConnect)
Grafana    ◀── PodMonitor ──── CNPG built-in exporter
Kafka UI   ────────────────────────────────────────────────┘
```

## Требования

- minikube ≥ 1.33 или kind ≥ 0.23
- kubectl ≥ 1.28
- Helm ≥ 3.14
- 2 CPU / 18 GB RAM (рекомендуется для полного стенда без monitoring)

## Быстрый старт (minikube, рекомендуется поэтапный запуск)

### 1. Запуск minikube

```bash
# Для машины с 2 физическими CPU и 18 GB RAM:
minikube start --memory=8192 --cpus=2 --driver=docker

# Если машина мощнее (4+ CPU, 16+ GB RAM):
minikube start --memory=12288 --cpus=4 --driver=docker
```

Суммарное потребление dev-профиля:
- **Минимум** (только Kafka 1 брокер + Postgres): ~2 GB RAM, ~1 CPU
- **Комфортно** (+ monitoring + kafka-ui): ~6 GB RAM, ~1.5 CPU

### 2. Установка операторов

```bash
# Создать неймспейсы
kubectl create namespace kafka
kubectl create namespace postgres
kubectl create namespace monitoring

# Добавить Helm-репозитории
helm repo add strimzi https://strimzi.io/charts/
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add provectus https://provectus.github.io/kafka-ui-charts
helm repo update

# Strimzi Operator
helm install strimzi-operator strimzi/strimzi-kafka-operator \
  --namespace kafka \
  --version 0.41.0 \
  --wait --timeout 5m

# CloudNativePG Operator
helm install cnpg-operator cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --create-namespace \
  --version 0.21.0 \
  --wait --timeout 5m
```

### 3. Сборка зависимостей umbrella-чарта

```bash
cd infra/helm
helm dependency build monitoring
helm dependency build kafka-ui
helm dependency build umbrella
```

### 4. Этап 1 — только Kafka + Postgres (outbox-поток)

**Начать именно с этого**, особенно на слабом железе:

```bash
helm install outbox-stack helm/umbrella \
  --values helm/umbrella/values.yaml \
  --values helm/umbrella/values-dev.yaml \
  --set monitoring.enabled=false \
  --set kafkaUi.enabled=false \
  --namespace default \
  --timeout 15m \
  --wait
```

Дождаться готовности:

```bash
kubectl wait kafka/kafka-cluster --for=condition=Ready --timeout=600s -n kafka
kubectl wait cluster/postgres-cluster --for=condition=Ready --timeout=600s -n postgres
kubectl wait kafkaconnect/debezium-connect --for=condition=Ready --timeout=300s -n kafka
kubectl wait job/postgres-migrations --for=condition=Complete --timeout=300s -n postgres
```

Проверить нагрузку:
```bash
kubectl top nodes
kubectl top pods -n kafka
kubectl top pods -n postgres
```

### 5. Этап 2 — включить Kafka UI

```bash
helm upgrade outbox-stack helm/umbrella \
  --values helm/umbrella/values.yaml \
  --values helm/umbrella/values-dev.yaml \
  --set monitoring.enabled=false \
  --set kafkaUi.enabled=true \
  --namespace default \
  --timeout 10m \
  --wait
```

### 6. Этап 3 — включить мониторинг

```bash
helm upgrade outbox-stack helm/umbrella \
  --values helm/umbrella/values.yaml \
  --values helm/umbrella/values-dev.yaml \
  --set monitoring.enabled=true \
  --set kafkaUi.enabled=true \
  --namespace default \
  --timeout 15m \
  --wait
```

## Смена пароля Debezium (обязательно перед продакшеном)

Secrets в `kafka/templates/kafka-connect.yaml` и `postgres/templates/cluster.yaml` содержат плейсхолдерные пароли. Перед деплоем создайте свои секреты:

```bash
kubectl create secret generic debezium-credentials \
  --namespace kafka \
  --from-literal=username=debezium \
  --from-literal=password='YOUR_SECURE_PASSWORD' \
  --dry-run=client -o yaml | kubectl apply -f -

# Обновить то же самое в namespace postgres (для init job)
kubectl create secret generic debezium-credentials \
  --namespace postgres \
  --from-literal=username=debezium \
  --from-literal=password='YOUR_SECURE_PASSWORD' \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Проверка outbox → Kafka

```bash
# Вставить тестовое событие
kubectl exec -n postgres \
  $(kubectl get pod -n postgres -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}') \
  -- psql -U appuser -d appdb -c "
    INSERT INTO outbox (aggregate_type, aggregate_id, event_type, payload)
    VALUES (
      'orders',
      gen_random_uuid()::text,
      'OrderCreated',
      '{\"customerId\": \"test-123\", \"totalAmount\": 99.99}'::jsonb
    );
  "

# Прочитать из Kafka (через kcat-pod)
kubectl run kcat --image=edenhill/kcat:1.7.1 --rm -it --restart=Never -- \
  kcat -b kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092 \
       -t outbox.events.orders \
       -C -o beginning -e
```

## Grafana

```bash
# Port-forward
kubectl port-forward -n monitoring svc/outbox-stack-grafana 3000:80

# Открыть: http://localhost:3000
# Логин: admin
# Пароль: admin  (задаётся в monitoring/values.yaml → grafana.adminPassword)
```

Готовые дашборды (загружаются автоматически через ConfigMap):
- **Kafka Cluster Overview** — under-replicated partitions, consumer lag, throughput
- **PostgreSQL Overview** — replication lag, connections, cache hit ratio

## Kafka UI

```bash
kubectl port-forward -n default svc/outbox-stack-kafka-ui 8080:80
# Открыть: http://localhost:8080
```

Или через Ingress — раскомментировать секцию `ingress` в `kafka-ui/values.yaml`.

## Масштабирование брокеров

```bash
# Увеличить до 3 брокеров (не забудьте, что нужно место в кластере)
helm upgrade outbox-stack helm/umbrella \
  --values helm/umbrella/values.yaml \
  --set kafka.replicas=3 \
  --set kafka.topicReplicationFactor=3

# Уменьшить обратно до 1
helm upgrade outbox-stack helm/umbrella \
  --values helm/umbrella/values.yaml \
  --values helm/umbrella/values-dev.yaml
```

## Диагностика и логи

### Kafka брокер

```bash
# Все брокеры
kubectl logs -n kafka -l strimzi.io/name=kafka-cluster-kafka -c kafka --tail=100 -f

# Конкретный брокер
kubectl logs -n kafka kafka-cluster-kafka-0 -c kafka --tail=100 -f
```

### Kafka Connect / Debezium

```bash
# Логи коннектора (ошибки CDC, replication slot)
kubectl logs -n kafka -l strimzi.io/name=debezium-connect-connect --tail=100 -f

# Статус коннектора
kubectl get kafkaconnector debezium-outbox-connector -n kafka -o yaml

# REST API Debezium (через port-forward)
kubectl port-forward -n kafka svc/debezium-connect-connect-api 8083:8083
curl http://localhost:8083/connectors/debezium-outbox-connector/status | jq .
```

### PostgreSQL

```bash
# Логи primary
kubectl logs -n postgres \
  $(kubectl get pod -n postgres -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}') \
  --tail=100 -f

# Активные replication slots
kubectl exec -n postgres \
  $(kubectl get pod -n postgres -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}') \
  -- psql -U appuser -d appdb -c "SELECT * FROM pg_replication_slots;"
```

### Описание проблемных ресурсов

```bash
kubectl describe kafka/kafka-cluster -n kafka
kubectl describe kafkaconnect/debezium-connect -n kafka
kubectl describe cluster/postgres-cluster -n postgres
kubectl get events -n kafka --sort-by='.lastTimestamp'
kubectl get events -n postgres --sort-by='.lastTimestamp'
```

## Эксперимент: отказ брокера

```bash
# Удалить один из брокеров под нагрузкой
kubectl delete pod kafka-cluster-kafka-0 -n kafka

# В Kafka UI / Grafana наблюдать:
# 1. Under-replicated partitions → briefly > 0
# 2. Переизбрание лидера партиции
# 3. Consumer lag растёт пока брокер восстанавливается
# 4. После возврата брокера — балансировка партиций
```

## TODO / Ограничения (что доработать для продакшена)

- **Secrets management** — сейчас пароли в Helm values как плейсхолдеры. Использовать External Secrets Operator + Vault/AWS Secrets Manager.
- **TLS между брокерами** — включить `tls: true` в Strimzi listeners и настроить `KafkaUser` с сертификатами.
- **Backup PostgreSQL** — настроить CNPG Barman plugin для резервных копий в S3/GCS.
- **Schema Registry** — добавить Karapace для версионирования формата сообщений вместо чистого JSON в outbox.
- **PodDisruptionBudget** — добавить PDB для Kafka-брокеров чтобы `maxUnavailable=1` при rolling updates.
- **Replication slot WAL bloat** — если Debezium лаганёт, нарастёт WAL. Настроить `max_slot_wal_keep_size` в CNPG postgresql parameters.
- **KRaft mode** — Strimzi поддерживает KRaft (без Zookeeper) начиная с 0.39. Упрощает операционку, но в учебном стенде Zookeeper оставлен для наглядности.
- **External access** — для подключения kafka-клиентов снаружи кластера настроить `NodePort`/`LoadBalancer` listener и обновить `kafka-ui/values.yaml` `bootstrapServers`.
- **Alerting** — настроить Alertmanager rules для critical alerts: under-replicated partitions > 0, consumer lag > threshold, Postgres replication lag.
