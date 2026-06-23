# Troubleshooting: Kafka + PostgreSQL Outbox Stand

Быстрая диагностика — запусти сначала:
```bash
./stand.sh doctor
```

Поток данных и точки отказа:
```
[1] PostgreSQL  →  [2] Debezium  →  [3] Kafka  →  [4] Консьюмер
     (outbox)       (CDC/WAL)       (topic)        (ваш сервис)
```

---

## Шаг 0: быстрый осмотр

```bash
# Есть ли что-то не Running/Completed?
kubectl get pods -n kafka && kubectl get pods -n postgres

# Коннектор живой?
kubectl get kafkaconnector debezium-outbox-connector -n kafka \
  -o jsonpath='{.status.conditions[0].type}:{.status.conditions[0].status}'
# → Ready:True  (норма)

# Что случилось и когда
kubectl get events -n kafka --sort-by='.lastTimestamp' | tail -15
kubectl get events -n postgres --sort-by='.lastTimestamp' | tail -15
```

---

## Отказ 1: PostgreSQL

**Симптомы:** коннектор падает с `Connection refused` или `PSQLException`,
новые INSERT не проходят, приложение возвращает ошибку.

### Проверка

```bash
# Статус кластера CNPG
kubectl get cluster postgres-cluster -n postgres

# Под жив?
kubectl get pods -n postgres

# Логи
kubectl logs -n postgres postgres-cluster-1 --tail=50 \
  | grep -iE "FATAL|ERROR|panic"

# Replication slots — КРИТИЧНО
# Если Debezium упал, слот остаётся открытым → WAL накапливается → диск кончается
kubectl exec -n postgres postgres-cluster-1 -- \
  bash -c "PGPASSWORD='appuser_password_change_me' psql -h localhost \
  -U appuser -d appdb -c \
  'SELECT slot_name, active, pg_size_pretty(
     pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_lag
   FROM pg_replication_slots;'"
```

### Решения

```bash
# CNPG сам рестартует pod — просто ждём
kubectl wait cluster/postgres-cluster -n postgres \
  --for=condition=Ready --timeout=300s

# Принудительный рестарт пода (CNPG сам выберет нового primary)
kubectl delete pod -n postgres postgres-cluster-1

# Если WAL растёт и Debezium точно не вернётся — дропнуть слот вручную
# ⚠ ОСТОРОЖНО: Debezium начнёт CDC с нуля (может задублировать события)
kubectl exec -n postgres postgres-cluster-1 -- \
  bash -c "PGPASSWORD='appuser_password_change_me' psql -h localhost \
  -U appuser -d appdb -c \
  \"SELECT pg_drop_replication_slot('debezium_outbox');\""
```

---

## Отказ 2: Debezium / KafkaConnect

Самое частое место отказа. Три возможных состояния задачи: `RUNNING`, `PAUSED`, `FAILED`.

### Проверка

```bash
# Статус коннектора и задачи
kubectl get kafkaconnector debezium-outbox-connector -n kafka \
  -o jsonpath='{.status.connectorStatus}' | python3 -m json.tool | grep -A2 '"state"'

# Полный стектрейс последней ошибки
kubectl get kafkaconnector debezium-outbox-connector -n kafka \
  -o jsonpath='{.status.connectorStatus.tasks[0].trace}' | head -20

# Логи воркера — только ошибки
kubectl logs -n kafka debezium-connect-connect-0 \
  | grep -iE "ERROR|FATAL|Exception" | grep -v "^\s*at " | tail -20
```

### Типовые ошибки

| Ошибка в trace | Причина | Действие |
|---|---|---|
| `Connection refused` к postgres | PostgreSQL недоступен | Ждать восстановления PG |
| `replication slot ... does not exist` | Слот удалили вручную | Перезапустить коннектор — создаст новый |
| `password authentication failed` | Неверный пароль | Проверить `connector.postgresPassword` в values |
| `Tolerance exceeded` + `IllegalArgumentException` | Ошибка в SMT-трансформации | Смотреть trace, проверить `route.topic.replacement` |
| `Not leader for partition` | Брокер Kafka упал | Ждать восстановления брокера |

### Решения

```bash
# Перезапустить задачу (без потери позиции в WAL)
kubectl exec -n kafka debezium-connect-connect-0 -- \
  curl -s -X POST \
  http://localhost:8083/connectors/debezium-outbox-connector/tasks/0/restart \
  | python3 -m json.tool

# Перезапустить весь коннектор
kubectl exec -n kafka debezium-connect-connect-0 -- \
  curl -s -X POST \
  http://localhost:8083/connectors/debezium-outbox-connector/restart \
  | python3 -m json.tool

# Перезапустить pod Connect (ядерный вариант — пересоздаёт worker)
kubectl delete pod -n kafka debezium-connect-connect-0

# Посмотреть текущий конфиг коннектора через REST
kubectl exec -n kafka debezium-connect-connect-0 -- \
  curl -s http://localhost:8083/connectors/debezium-outbox-connector/config \
  | python3 -m json.tool
```

---

## Отказ 3: Kafka broker

**Симптомы:** Debezium пишет, но сообщения не доходят. Или Debezium
падает с `Not leader for partition`. Consumer lag растёт.

### Проверка

```bash
# Брокер жив?
kubectl get pods -n kafka kafka-cluster-kafka-0
kubectl get kafka kafka-cluster -n kafka -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'

# Under-replicated partitions — главный индикатор
# В норме: 0. Если > 0 — данные под угрозой потери
kubectl exec -n kafka kafka-cluster-kafka-0 -c kafka -- \
  bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe --under-replicated-partitions

# Логи брокера
kubectl logs -n kafka kafka-cluster-kafka-0 -c kafka \
  | grep -iE "ERROR|FATAL|NotLeader|UnderReplicated" | tail -20

# Сколько сообщений в топике (по партициям)
kubectl exec -n kafka kafka-cluster-kafka-0 -c kafka -- \
  bin/kafka-get-offsets.sh \
  --bootstrap-server localhost:9092 \
  --topic outbox.events.orders

# Диск брокера
kubectl exec -n kafka kafka-cluster-kafka-0 -c kafka -- df -h /var/lib/kafka/data
```

### Решения

```bash
# Strimzi сам рестартует брокер — просто ждём
kubectl wait kafka/kafka-cluster -n kafka --for=condition=Ready --timeout=600s

# Принудительный рестарт брокера
kubectl delete pod -n kafka kafka-cluster-kafka-0

# Диск закончился — почистить старые сегменты (меняем retention)
kubectl exec -n kafka kafka-cluster-kafka-0 -c kafka -- \
  bin/kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name outbox.events.orders \
  --alter --add-config retention.ms=3600000  # 1 час вместо 7 дней
```

---

## Отказ 4: события есть в outbox, но не доходят до Kafka

Самый коварный — всё `Running`, но доставки нет.

### Проверка

```bash
# Сколько событий ждут в outbox?
kubectl exec -n postgres postgres-cluster-1 -- \
  bash -c "PGPASSWORD='appuser_password_change_me' psql -h localhost \
  -U appuser -d appdb -tAc 'SELECT count(*) FROM outbox;'"

# Последние записи в outbox (смотрим created_at)
kubectl exec -n postgres postgres-cluster-1 -- \
  bash -c "PGPASSWORD='appuser_password_change_me' psql -h localhost \
  -U appuser -d appdb -c \
  'SELECT id, aggregate_type, event_type, created_at FROM outbox ORDER BY created_at DESC LIMIT 5;'"

# Offset в Kafka растёт?
kubectl exec -n kafka kafka-cluster-kafka-0 -c kafka -- \
  bin/kafka-run-class.sh kafka.tools.GetOffsetShell \
  --bootstrap-server localhost:9092 --topic outbox.events.orders

# Consumer lag по группам
kubectl exec -n kafka kafka-cluster-kafka-0 -c kafka -- \
  bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --describe --all-groups 2>/dev/null | grep -v "^$\|CONSUMER\|GROUP"
```

### Частые причины

- **Debezium читает WAL с задержкой** — нормально при низкой нагрузке. Увеличь `heartbeat.interval.ms`.
- **Неверный `table.include.list`** — Debezium следит не за той таблицей. Проверь конфиг коннектора.
- **Ошибка в SMT** — трансформация падает тихо. Смотри `tasks[0].trace`.
- **Нет publication в PG** — `SELECT * FROM pg_publication;` должна быть `debezium_publication`.

---

## Отказ 5: consumer lag растёт

Это значит сообщения в Kafka есть, но ваш консьюмер (сервис) отстаёт.

```bash
# Посмотреть lag по группам
kubectl exec -n kafka kafka-cluster-kafka-0 -c kafka -- \
  bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --describe --all-groups 2>/dev/null

# Прочитать последние сообщения вручную
./stand.sh tail orders 10
```

---

## Чеклист при инциденте

```
1. ./stand.sh doctor                          → автодиагностика всего

2. kubectl get pods -n kafka,postgres          → CrashLoop? → kubectl logs + describe

3. kafkaconnector Ready:True?                  → НЕТ → .status.tasks[0].trace
   task state RUNNING?                         → НЕТ → restart task через REST API

4. Строки в outbox появляются?                → НЕТ → проблема в приложении / PG
   Kafka offset растёт?                       → НЕТ → Debezium не читает WAL
   pg_replication_slots.active = true?         → НЕТ → коннектор отвалился от слота

5. Grafana → Consumer Lag > 0 долго?          → консьюмер отстаёт
   Grafana → Under-replicated partitions > 0? → проблема репликации Kafka
   Grafana → WAL lag в слоте > 1GB?           → Debezium завис, диск под угрозой
```

---

## Полезные команды одной строкой

```bash
# Перезапустить всё разом (осторожно на проде)
kubectl delete pod -n kafka debezium-connect-connect-0 kafka-cluster-kafka-0 \
  && kubectl delete pod -n postgres postgres-cluster-1

# Посмотреть конфигурацию Debezium живьём
kubectl exec -n kafka debezium-connect-connect-0 -- \
  curl -s http://localhost:8083/connectors/debezium-outbox-connector/config \
  | python3 -m json.tool

# Проверить publication в PostgreSQL
kubectl exec -n postgres postgres-cluster-1 -- \
  bash -c "PGPASSWORD='appuser_password_change_me' psql -h localhost \
  -U appuser -d appdb -c 'SELECT * FROM pg_publication;'"

# Tail логов всех Kafka-компонентов разом (в отдельных терминалах)
kubectl logs -n kafka -l strimzi.io/cluster=kafka-cluster -c kafka -f --max-log-requests 5
```
