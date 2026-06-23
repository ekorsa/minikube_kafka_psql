#!/usr/bin/env bash
# stand.sh — управление учебным стендом kafka+postgres+debezium
# Использование:
#   ./stand.sh start              # фаза 1: kafka + postgres
#   ./stand.sh start --with-ui    # + kafka-ui
#   ./stand.sh start --full       # + kafka-ui + monitoring
#   ./stand.sh stop               # minikube stop (состояние сохраняется)
#   ./stand.sh destroy            # helm uninstall + minikube delete
#   ./stand.sh status             # состояние подов и ресурсов
#   ./stand.sh build-image        # пересобрать docker-образ Debezium
#   ./stand.sh smoke-test         # вставить событие и прочитать из Kafka

set -euo pipefail

# ── константы ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINIKUBE_MEMORY=8192
MINIKUBE_CPUS=2
MINIKUBE_DRIVER=docker

DOCKER_IMAGE="strimzi-debezium-postgres:2.7.3"
DOCKERFILE="$SCRIPT_DIR/infra/docker/debezium-connect/Dockerfile"
DOCKER_CONTEXT="$SCRIPT_DIR/infra/docker/debezium-connect"

STRIMZI_VERSION="0.41.0"
CNPG_VERSION="0.21.0"

HELM_RELEASE="outbox-stack"
HELM_CHART="$SCRIPT_DIR/infra/helm/umbrella"
HELM_VALUES="$SCRIPT_DIR/infra/helm/umbrella/values.yaml"
HELM_VALUES_DEV="$SCRIPT_DIR/infra/helm/umbrella/values-dev.yaml"
HELM_TIMEOUT_INSTALL="15m"
HELM_TIMEOUT_UPGRADE="10m"

# ── цвета ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}✔${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
log_err()   { echo -e "${RED}✘${NC}  $*" >&2; }
log_step()  { echo -e "\n${BLUE}${BOLD}▶ $*${NC}"; }
log_done()  { echo -e "${CYAN}${BOLD}   done${NC}"; }

die() { log_err "$*"; exit 1; }

# ── minikube ───────────────────────────────────────────────────────────────────
ensure_minikube() {
    log_step "Проверка minikube"

    local status
    status=$(minikube status --format='{{.Host}}' 2>/dev/null || echo "NotFound")

    case "$status" in
        Running)
            log_info "minikube уже запущен ($(minikube ip))"
            ;;
        Stopped)
            log_info "minikube остановлен — запускаю (сохранённый профиль)"
            minikube start
            log_done
            ;;
        NotFound|"")
            log_info "minikube не найден — создаю новый профиль"
            minikube start \
                --memory="${MINIKUBE_MEMORY}" \
                --cpus="${MINIKUBE_CPUS}" \
                --driver="${MINIKUBE_DRIVER}"
            log_done
            ;;
        *)
            die "Неожиданный статус minikube: $status"
            ;;
    esac
}

# ── docker-образ ───────────────────────────────────────────────────────────────
ensure_docker_image() {
    log_step "Docker-образ Debezium ($DOCKER_IMAGE)"

    eval "$(minikube docker-env)"

    if docker image inspect "$DOCKER_IMAGE" &>/dev/null; then
        log_info "Образ $DOCKER_IMAGE уже существует в minikube"
    else
        log_warn "Образ не найден — собираю"
        build_image
    fi
}

build_image() {
    [[ -f "$DOCKERFILE" ]] || die "Dockerfile не найден: $DOCKERFILE"
    log_info "Сборка $DOCKER_IMAGE из $DOCKERFILE"
    eval "$(minikube docker-env)"
    docker build -t "$DOCKER_IMAGE" "$DOCKER_CONTEXT"
    log_done
}

# ── kubernetes namespaces ──────────────────────────────────────────────────────
ensure_namespaces() {
    log_step "Namespaces"
    for ns in kafka postgres monitoring cnpg-system; do
        if kubectl get namespace "$ns" &>/dev/null; then
            log_info "namespace $ns уже существует"
        else
            kubectl create namespace "$ns"
            log_info "namespace $ns создан"
        fi
    done
}

# ── helm repos ─────────────────────────────────────────────────────────────────
ensure_helm_repos() {
    log_step "Helm репозитории"
    local repos_added=0

    _add_repo() {
        local name="$1" url="$2"
        if helm repo list 2>/dev/null | grep -q "^${name}[[:space:]]"; then
            log_info "repo $name уже добавлен"
        else
            helm repo add "$name" "$url"
            repos_added=$((repos_added + 1))
            log_info "repo $name добавлен"
        fi
    }

    _add_repo strimzi       https://strimzi.io/charts/
    _add_repo cnpg          https://cloudnative-pg.github.io/charts
    _add_repo prometheus-community https://prometheus-community.github.io/helm-charts
    _add_repo provectus     https://provectus.github.io/kafka-ui-charts

    if [[ $repos_added -gt 0 ]]; then
        helm repo update
        log_done
    fi
}

# ── операторы ─────────────────────────────────────────────────────────────────
ensure_operators() {
    log_step "Операторы Kubernetes"

    if helm list -n kafka 2>/dev/null | grep -q "strimzi-operator"; then
        log_info "Strimzi operator уже установлен"
    else
        log_info "Устанавливаю Strimzi $STRIMZI_VERSION"
        helm install strimzi-operator strimzi/strimzi-kafka-operator \
            --namespace kafka \
            --version "$STRIMZI_VERSION" \
            --wait --timeout 5m
        log_done
    fi

    if helm list -n cnpg-system 2>/dev/null | grep -q "cnpg-operator"; then
        log_info "CloudNativePG operator уже установлен"
    else
        log_info "Устанавливаю CloudNativePG $CNPG_VERSION"
        helm install cnpg-operator cnpg/cloudnative-pg \
            --namespace cnpg-system \
            --version "$CNPG_VERSION" \
            --wait --timeout 5m
        log_done
    fi
}

# ── сборка helm-зависимостей ──────────────────────────────────────────────────
build_helm_deps() {
    log_step "Сборка Helm зависимостей"
    # Сначала чарты с внешними зависимостями, потом umbrella
    for chart in monitoring kafka-ui umbrella; do
        log_info "helm dependency build $chart"
        helm dependency build "$SCRIPT_DIR/infra/helm/$chart" 2>&1 | grep -v "^Saving\|^Deleting" || true
    done
    log_done
}

# ── установка / обновление стенда ─────────────────────────────────────────────
deploy_stack() {
    local with_ui="${1:-false}"
    local with_monitoring="${2:-false}"
    local timeout

    log_step "Деплой стенда (helm)"

    local extra_flags=()
    extra_flags+=("--set" "monitoring.enabled=${with_monitoring}")
    extra_flags+=("--set" "kafkaUi.enabled=${with_ui}")

    local current_status
    current_status=$(helm status "$HELM_RELEASE" --namespace default 2>/dev/null \
        | grep STATUS: | awk '{print $2}' || echo "not-installed")

    if [[ "$current_status" == "not-installed" ]]; then
        log_info "Первичная установка (helm install)"
        timeout="$HELM_TIMEOUT_INSTALL"
        helm install "$HELM_RELEASE" "$HELM_CHART" \
            --values "$HELM_VALUES" \
            --values "$HELM_VALUES_DEV" \
            "${extra_flags[@]}" \
            --namespace default \
            --timeout "$timeout" \
            --wait
    else
        log_info "Обновление (helm upgrade, статус: $current_status)"
        timeout="$HELM_TIMEOUT_UPGRADE"
        helm upgrade "$HELM_RELEASE" "$HELM_CHART" \
            --values "$HELM_VALUES" \
            --values "$HELM_VALUES_DEV" \
            "${extra_flags[@]}" \
            --namespace default \
            --timeout "$timeout" \
            --wait
    fi

    log_done
}

# ── ожидание готовности ────────────────────────────────────────────────────────
wait_for_ready() {
    log_step "Ожидание готовности компонентов"

    log_info "Kafka broker..."
    kubectl wait kafka/kafka-cluster \
        --for=condition=Ready --timeout=600s -n kafka 2>/dev/null || true

    log_info "PostgreSQL cluster..."
    kubectl wait cluster/postgres-cluster \
        --for=condition=Ready --timeout=600s -n postgres 2>/dev/null || true

    log_info "KafkaConnect..."
    kubectl wait kafkaconnect/debezium-connect \
        --for=condition=Ready --timeout=300s -n kafka 2>/dev/null || true

    log_info "Миграции PostgreSQL..."
    kubectl wait job/postgres-migrations \
        --for=condition=Complete --timeout=300s -n postgres 2>/dev/null || true

    log_done
}

# ── статус ────────────────────────────────────────────────────────────────────
cmd_status() {
    echo -e "\n${BOLD}═══ Миnikube ══════════════════════════════════════════${NC}"
    minikube status 2>/dev/null || echo "не запущен"

    echo -e "\n${BOLD}═══ Поды kafka ════════════════════════════════════════${NC}"
    kubectl get pods -n kafka --no-headers 2>/dev/null \
        | awk '{printf "  %-50s %-10s %s\n", $1, $3, $4}' \
        || echo "  нет данных"

    echo -e "\n${BOLD}═══ Поды postgres ═════════════════════════════════════${NC}"
    kubectl get pods -n postgres --no-headers 2>/dev/null \
        | awk '{printf "  %-50s %-10s %s\n", $1, $3, $4}' \
        || echo "  нет данных"

    echo -e "\n${BOLD}═══ KafkaConnect / KafkaConnector ═════════════════════${NC}"
    kubectl get kafkaconnect,kafkaconnector -n kafka --no-headers 2>/dev/null \
        | awk '{printf "  %-55s %s\n", $1, $NF}' \
        || echo "  нет данных"

    echo -e "\n${BOLD}═══ Ресурсы (nodes) ════════════════════════════════════${NC}"
    kubectl top nodes 2>/dev/null || echo "  metrics-server не доступен"

    echo -e "\n${BOLD}═══ Ресурсы (поды kafka) ═══════════════════════════════${NC}"
    kubectl top pods -n kafka 2>/dev/null || echo "  нет данных"

    echo -e "\n${BOLD}═══ Ресурсы (поды postgres) ════════════════════════════${NC}"
    kubectl top pods -n postgres 2>/dev/null || echo "  нет данных"

    echo
}

# ── smoke test ────────────────────────────────────────────────────────────────
cmd_smoke_test() {
    log_step "Smoke test: outbox → Kafka"

    local pg_pod
    pg_pod=$(kubectl get pod -n postgres -l cnpg.io/instanceRole=primary \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) \
        || die "Не найден primary postgres pod"

    local aggregate_id
    aggregate_id=$(kubectl exec -n postgres "$pg_pod" -- \
        bash -c "cat /proc/sys/kernel/random/uuid" 2>/dev/null \
        || cat /proc/sys/kernel/random/uuid)

    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    log_info "Вставляю событие (aggregate_id=$aggregate_id)"
    kubectl exec -n postgres "$pg_pod" -- \
        bash -c "PGPASSWORD='appuser_password_change_me' psql -h localhost -U appuser -d appdb -c \"
            INSERT INTO outbox (aggregate_type, aggregate_id, event_type, payload)
            VALUES ('orders', '$aggregate_id', 'OrderCreated',
                    '{\\\"customerId\\\": \\\"smoke-test\\\", \\\"amount\\\": 42, \\\"ts\\\": \\\"$ts\\\"}'::jsonb);
        \"" 2>&1 | grep -E "INSERT|ERROR"

    log_info "Жду 10 секунд (Debezium WAL latency)..."
    sleep 10

    log_info "Читаю из Kafka topic outbox.events.orders (последние 3 с каждой партиции)"
    kubectl run kcat-smoke-$$ \
        --image=edenhill/kcat:1.7.1 \
        --restart=Never -n kafka \
        --command -- \
        sh -c 'timeout 10 kcat -b kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092 \
               -t outbox.events.orders -C -o -3 -e -q 2>/dev/null; true' \
        &>/dev/null

    until kubectl get pod "kcat-smoke-$$" -n kafka --no-headers 2>/dev/null \
            | grep -qE "Completed|Error"; do
        sleep 1
    done

    local msgs
    msgs=$(kubectl logs "kcat-smoke-$$" -n kafka 2>/dev/null)
    kubectl delete pod "kcat-smoke-$$" -n kafka --now &>/dev/null

    if [[ -z "$msgs" ]]; then
        log_warn "Сообщений не найдено — проверь статус коннектора"
        return 1
    fi

    echo -e "\n  Последние сообщения:"
    echo "$msgs" | while IFS= read -r line; do
        echo "  $line" | python3 -c "
import sys, json
try:
    print('  ' + json.dumps(json.loads(sys.stdin.read()), ensure_ascii=False))
except:
    pass
" 2>/dev/null || echo "  $line"
    done

    log_info "smoke test пройден"
}

# ── send ─────────────────────────────────────────────────────────────────────
# Использование:
#   cmd_send <aggregate_type> <payload_json>
#   cmd_send <aggregate_type> <event_type> <payload_json>
cmd_send() {
    local aggregate_type="${1:-}"
    local event_type payload

    case $# in
        2) event_type="Event";  payload="$2" ;;
        3) event_type="$2";     payload="$3" ;;
        *) die "send: неверные аргументы
  Использование:
    $(basename "$0") send <aggregate_type> '<payload_json>'
    $(basename "$0") send <aggregate_type> <event_type> '<payload_json>'" ;;
    esac

    [[ -n "$aggregate_type" ]] || die "aggregate_type не может быть пустым"

    # Валидируем JSON и нормализуем (compact, single-quoted escaped) на хосте
    local escaped_payload err
    if ! escaped_payload=$(python3 -c "
import sys, json
raw = sys.argv[1]
try:
    parsed = json.loads(raw)
except json.JSONDecodeError as e:
    print(f'Невалидный JSON: {e}', file=sys.stderr)
    sys.exit(1)
print(json.dumps(parsed, ensure_ascii=False).replace(\"'\", \"''\"))
" "$payload" 2>/tmp/stand_py_err); then
        err=$(cat /tmp/stand_py_err)
        die "${err:-Невалидный JSON}"
    fi

    local pg_pod
    pg_pod=$(kubectl get pod -n postgres -l cnpg.io/instanceRole=primary \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) \
        || die "Не найден primary postgres pod"

    local aggregate_id
    aggregate_id=$(cat /proc/sys/kernel/random/uuid)

    log_step "Отправка события в outbox"
    log_info "aggregate_type : $aggregate_type"
    log_info "event_type     : $event_type"
    log_info "aggregate_id   : $aggregate_id"
    log_info "payload        : $payload"

    # SQL строится на хосте и передаётся в psql через stdin (-i).
    # Это безопаснее, чем экранировать через несколько уровней bash-кавычек.
    local sql
    sql="INSERT INTO outbox (aggregate_type, aggregate_id, event_type, payload)
VALUES ('${aggregate_type}', '${aggregate_id}', '${event_type}', '${escaped_payload}'::jsonb)
RETURNING id;"

    local row_id
    row_id=$(echo "$sql" | kubectl exec -i -n postgres "$pg_pod" -- \
        bash -c "PGPASSWORD='appuser_password_change_me' psql -h localhost -U appuser -d appdb -tA" \
        2>/dev/null) || die "Ошибка INSERT"

    row_id=$(echo "$row_id" | grep -E '^[0-9a-f-]{36}$' | head -1)
    log_info "Вставлено: outbox.id=${row_id}"
    echo
    echo -e "  Топик Kafka: ${CYAN}outbox.events.${aggregate_type}${NC}"
    echo -e "  Прочитать:   ${CYAN}./stand.sh tail ${aggregate_type}${NC}"
}

# ── tail — читаем последние N сообщений из топика ────────────────────────────
cmd_tail() {
    local aggregate_type="${1:-orders}"
    local count="${2:-10}"
    local topic="outbox.events.${aggregate_type}"

    log_step "Последние $count сообщений из $topic"

    local pod_name="kcat-tail-$$"
    kubectl run "$pod_name" \
        --image=edenhill/kcat:1.7.1 \
        --restart=Never -n kafka \
        --command -- \
        sh -c "timeout 10 kcat \
            -b kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092 \
            -t $topic -C -o -${count} -e -q 2>/dev/null; true" \
        &>/dev/null

    until kubectl get pod "$pod_name" -n kafka --no-headers 2>/dev/null \
            | grep -qE "Completed|Error"; do
        sleep 1
    done

    local msgs
    msgs=$(kubectl logs "$pod_name" -n kafka 2>/dev/null)
    kubectl delete pod "$pod_name" -n kafka --now &>/dev/null

    if [[ -z "$msgs" ]]; then
        log_warn "Топик пуст или не существует: $topic"
        return 0
    fi

    echo "$msgs" | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        print(json.dumps(json.loads(line), indent=2, ensure_ascii=False))
    except Exception:
        print(line)
    print()
"
}

# ── включить / выключить мониторинг на живом стенде ──────────────────────────
cmd_monitoring() {
    local action="${1:-on}"
    case "$action" in
        on|enable)   local enabled=true  label="Включаю мониторинг" ;;
        off|disable) local enabled=false label="Выключаю мониторинг" ;;
        *) die "monitoring: укажи on или off" ;;
    esac

    local current_status
    current_status=$(helm status "$HELM_RELEASE" --namespace default 2>/dev/null \
        | grep STATUS: | awk '{print $2}' || echo "not-installed")
    [[ "$current_status" == "not-installed" ]] && \
        die "Стенд не запущен — сначала './stand.sh start'"

    # Узнаём текущее состояние kafka-ui чтобы не сбросить его
    local current_ui
    current_ui=$(helm get values "$HELM_RELEASE" --namespace default -o json 2>/dev/null \
        | python3 -c "import sys,json; v=json.load(sys.stdin); print(str(v.get('kafkaUi',{}).get('enabled',False)).lower())" \
        2>/dev/null || echo "false")

    log_step "$label"
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - &>/dev/null
    build_helm_deps

    if [[ "$enabled" == "true" ]]; then
        log_info "Установка CRDs Prometheus Operator (требуется перед первым включением)"
        local kps_tgz="$SCRIPT_DIR/infra/helm/monitoring/charts/kube-prometheus-stack-58.4.0.tgz"
        if [[ -f "$kps_tgz" ]]; then
            helm show crds "$kps_tgz" | kubectl apply --server-side -f - 2>&1 \
                | grep -E "created|configured|unchanged|error" | head -10
        else
            log_warn "kube-prometheus-stack tgz не найден: $kps_tgz (пропускаю установку CRDs)"
        fi
    fi

    helm upgrade "$HELM_RELEASE" "$HELM_CHART" \
        --values "$HELM_VALUES" \
        --values "$HELM_VALUES_DEV" \
        --set "monitoring.enabled=${enabled}" \
        --set "kafkaUi.enabled=${current_ui}" \
        --namespace default \
        --timeout 10m \
        --wait
    log_done

    if [[ "$enabled" == "true" ]]; then
        echo
        echo -e "  Grafana    → ${CYAN}./stand.sh pf grafana${NC}    (admin / admin)"
        echo -e "  Prometheus → ${CYAN}./stand.sh pf prometheus${NC}"
    fi
}

# ── port-forward ──────────────────────────────────────────────────────────────
cmd_pf() {
    local target="${1:-}"
    local bg=false

    # Разбираем аргументы: ./stand.sh pf grafana [--bg]
    local args=()
    for arg in "$@"; do
        case "$arg" in
            --bg) bg=true ;;
            *)    args+=("$arg") ;;
        esac
    done
    target="${args[0]:-}"

    # Таблица: target → namespace, svc-selector, local-port, remote-port, url
    # svc-selector — часть имени сервиса (grep)
    case "$target" in
        grafana)
            local ns=default svc_grep="grafana" lport=3000 rport=80
            local url="http://localhost:3000  (admin / admin)"
            ;;
        prometheus)
            local ns=default svc_grep="kube-promethe-prometheus$" lport=9090 rport=9090
            local url="http://localhost:9090"
            ;;
        kafka-ui|ui)
            local ns=default svc_grep="kafka-ui" lport=8080 rport=80
            local url="http://localhost:8080"
            ;;
        connect|debezium)
            local ns=kafka svc_grep="connect-api" lport=8083 rport=8083
            local url="http://localhost:8083/connectors"
            ;;
        *)
            cat <<EOF
Использование: $(basename "$0") pf <сервис>

Доступные сервисы:
  grafana     Grafana UI          → http://localhost:3000  (admin / admin)
  prometheus  Prometheus UI       → http://localhost:9090
  kafka-ui    Kafka UI            → http://localhost:8080
  connect     Debezium REST API   → http://localhost:8083/connectors
EOF
            return 0
            ;;
    esac

    local svc
    svc=$(kubectl get svc -n "$ns" --no-headers 2>/dev/null \
        | awk '{print $1}' | grep -E "$svc_grep" | head -1 || true)

    if [[ -z "$svc" ]]; then
        log_err "Сервис '$target' не найден в namespace '$ns'"
        if [[ "$target" == "grafana" || "$target" == "prometheus" ]]; then
            echo -e "  Подсказка: мониторинг не включён → ${CYAN}./stand.sh monitoring on${NC}"
        elif [[ "$target" == "kafka-ui" || "$target" == "ui" ]]; then
            echo -e "  Подсказка: kafka-ui не включён → ${CYAN}./stand.sh start --with-ui${NC}"
        fi
        return 1
    fi

    log_step "Port-forward: $svc ($ns) → localhost:$lport"
    echo -e "  Открыть: ${CYAN}${url}${NC}"

    if [[ "$bg" == "true" ]]; then
        local pidfile="/tmp/stand-pf-${target}.pid"
        # Убиваем предыдущий процесс для этого сервиса, если был
        if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
            kill "$(cat "$pidfile")" 2>/dev/null
            log_info "Предыдущий port-forward ($target) остановлен"
        fi
        kubectl port-forward -n "$ns" "svc/$svc" "${lport}:${rport}" \
            >/tmp/stand-pf-${target}.log 2>&1 &
        echo $! > "$pidfile"
        sleep 1
        if kill -0 "$(cat "$pidfile")" 2>/dev/null; then
            log_info "Запущен в фоне (PID=$(cat "$pidfile"))"
            echo -e "  Остановить: ${CYAN}./stand.sh pf stop $target${NC}"
        else
            log_err "Port-forward не запустился — лог: /tmp/stand-pf-${target}.log"
            return 1
        fi
    else
        echo -e "  Остановить: ${BOLD}Ctrl+C${NC}"
        echo
        kubectl port-forward -n "$ns" "svc/$svc" "${lport}:${rport}"
    fi
}

cmd_pf_stop() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then
        # Остановить все фоновые port-forward
        local stopped=0
        for pidfile in /tmp/stand-pf-*.pid; do
            [[ -f "$pidfile" ]] || continue
            local name pid
            name=$(basename "$pidfile" .pid | sed 's/stand-pf-//')
            pid=$(cat "$pidfile")
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null
                log_info "Остановлен port-forward: $name (PID=$pid)"
                stopped=$((stopped + 1))
            fi
            rm -f "$pidfile"
        done
        [[ $stopped -eq 0 ]] && log_warn "Нет запущенных фоновых port-forward"
    else
        local pidfile="/tmp/stand-pf-${target}.pid"
        if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
            kill "$(cat "$pidfile")" 2>/dev/null
            rm -f "$pidfile"
            log_info "Остановлен port-forward: $target"
        else
            log_warn "Port-forward '$target' не запущен"
        fi
    fi
}

# ── остановка ─────────────────────────────────────────────────────────────────
cmd_stop() {
    log_step "Остановка minikube (состояние сохраняется)"
    minikube stop
    log_done
}

# ── полное удаление ────────────────────────────────────────────────────────────
cmd_destroy() {
    log_step "Удаление стенда"

    read -r -p "$(echo -e "${RED}Удалить minikube profile и все данные? [y/N]:${NC} ")" confirm
    [[ "${confirm,,}" == "y" ]] || { log_warn "Отменено"; return 0; }

    if helm list --namespace default 2>/dev/null | grep -q "$HELM_RELEASE"; then
        log_info "helm uninstall $HELM_RELEASE"
        helm uninstall "$HELM_RELEASE" --namespace default --wait --timeout 3m || true
    fi

    log_info "minikube delete"
    minikube delete

    log_done
}

# ── doctor ───────────────────────────────────────────────────────────────────
cmd_doctor() {
    local ok=0 warn=0 fail=0

    _pass()  { echo -e "  ${GREEN}✔${NC}  $*"; ok=$((ok+1)); }
    _warn()  { echo -e "  ${YELLOW}⚠${NC}  $*"; warn=$((warn+1)); }
    _fail()  { echo -e "  ${RED}✘${NC}  $*"; fail=$((fail+1)); }
    _info()  { echo -e "      ${BLUE}↳${NC} $*"; }
    _head()  { echo -e "\n${BOLD}$*${NC}"; }

    # ── 1. minikube ────────────────────────────────────────────────────────────
    _head "[ 1/5 ] minikube"
    local mk_status
    mk_status=$(minikube status --format='{{.Host}}' 2>/dev/null || echo "NotFound")
    if [[ "$mk_status" == "Running" ]]; then
        _pass "minikube Running ($(minikube ip 2>/dev/null))"
    else
        _fail "minikube не запущен (статус: $mk_status)"
        _info "Запусти: ./stand.sh start"
        echo; _summary $ok $warn $fail; return
    fi

    local disk_pct
    disk_pct=$(minikube ssh "df / | awk 'NR==2{print \$5}'" 2>/dev/null | tr -d ' %\r\n')
    if [[ -n "$disk_pct" ]]; then
        if   (( disk_pct >= 90 )); then _fail "Диск minikube ${disk_pct}% — критично"
        elif (( disk_pct >= 75 )); then _warn "Диск minikube ${disk_pct}% — следи"
        else                            _pass "Диск minikube ${disk_pct}%"
        fi
    fi

    # ── 2. PostgreSQL ──────────────────────────────────────────────────────────
    _head "[ 2/5 ] PostgreSQL (CNPG)"
    local pg_pod pg_phase
    pg_pod=$(kubectl get pod -n postgres -l cnpg.io/instanceRole=primary \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "$pg_pod" ]]; then
        _fail "Primary pod не найден"
    else
        local pg_ready
        pg_ready=$(kubectl get pod -n postgres "$pg_pod" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [[ "$pg_ready" == "True" ]]; then
            _pass "Primary pod $pg_pod Ready"
        else
            _fail "Primary pod $pg_pod не Ready"
            _info "kubectl logs -n postgres $pg_pod --tail=20"
        fi

        # Replication slot
        local slot_info
        slot_info=$(kubectl exec -n postgres "$pg_pod" -- \
            bash -c "PGPASSWORD='appuser_password_change_me' psql -h localhost \
            -U appuser -d appdb -tAc \
            \"SELECT active::text || '|' || coalesce(pg_size_pretty(
                pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)), '0')
              FROM pg_replication_slots WHERE slot_name='debezium_outbox';\"" \
            2>/dev/null | tr -d ' ')

        if [[ -z "$slot_info" ]]; then
            _warn "Replication slot 'debezium_outbox' не найден"
            _info "Debezium создаст его при первом подключении"
        else
            local slot_active slot_lag
            slot_active=$(echo "$slot_info" | cut -d'|' -f1)
            slot_lag=$(echo "$slot_info" | cut -d'|' -f2)
            if [[ "$slot_active" == "true" ]]; then
                _pass "Replication slot активен, WAL lag: $slot_lag"
            else
                _warn "Replication slot неактивен (Debezium отключён), WAL lag: $slot_lag"
                _info "WAL накапливается пока коннектор не reconnect'нется"
            fi
        fi

        # Кол-во событий в outbox
        local outbox_count
        outbox_count=$(kubectl exec -n postgres "$pg_pod" -- \
            bash -c "PGPASSWORD='appuser_password_change_me' psql -h localhost \
            -U appuser -d appdb -tAc 'SELECT count(*) FROM outbox;'" \
            2>/dev/null | tr -d ' ')
        [[ -n "$outbox_count" ]] && _pass "Строк в outbox: $outbox_count"
    fi

    # ── 3. Kafka broker ────────────────────────────────────────────────────────
    _head "[ 3/5 ] Kafka broker (Strimzi)"
    local kafka_ready
    kafka_ready=$(kubectl get kafka kafka-cluster -n kafka \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [[ "$kafka_ready" == "True" ]]; then
        _pass "Kafka CR Ready"
    else
        _fail "Kafka CR не Ready"
        _info "kubectl describe kafka kafka-cluster -n kafka"
    fi

    local broker_ready
    broker_ready=$(kubectl get pod -n kafka kafka-cluster-kafka-0 \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [[ "$broker_ready" == "True" ]]; then
        _pass "kafka-cluster-kafka-0 Ready"
    else
        _fail "kafka-cluster-kafka-0 не Ready"
        _info "kubectl logs -n kafka kafka-cluster-kafka-0 -c kafka --tail=30 | grep -iE 'ERROR|FATAL'"
    fi

    # Under-replicated partitions
    local urp
    urp=$(kubectl exec -n kafka kafka-cluster-kafka-0 -c kafka -- \
        bin/kafka-topics.sh --bootstrap-server localhost:9092 \
        --describe --under-replicated-partitions 2>/dev/null | grep -c "Topic:" || true)
    if [[ "$urp" -eq 0 ]]; then
        _pass "Under-replicated partitions: 0"
    else
        _fail "Under-replicated partitions: $urp — данные под угрозой"
        _info "kubectl logs -n kafka kafka-cluster-kafka-0 -c kafka | grep -i 'UnderReplicated'"
    fi

    # Offsets в топике
    local offsets
    offsets=$(kubectl exec -n kafka kafka-cluster-kafka-0 -c kafka -- \
        bin/kafka-get-offsets.sh \
        --bootstrap-server localhost:9092 \
        --topic outbox.events.orders 2>/dev/null \
        | awk -F: '{sum+=$3} END{print sum+0}' || echo "?")
    _pass "Сообщений в outbox.events.orders: $offsets"

    # ── 4. Debezium / KafkaConnect ─────────────────────────────────────────────
    _head "[ 4/5 ] Debezium / KafkaConnect"
    local connect_ready
    connect_ready=$(kubectl get kafkaconnect debezium-connect -n kafka \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [[ "$connect_ready" == "True" ]]; then
        _pass "KafkaConnect Ready"
    else
        _fail "KafkaConnect не Ready"
        _info "kubectl logs -n kafka debezium-connect-connect-0 | grep -iE 'ERROR|FATAL' | tail -5"
    fi

    local conn_state task_state
    conn_state=$(kubectl get kafkaconnector debezium-outbox-connector -n kafka \
        -o jsonpath='{.status.connectorStatus.connector.state}' 2>/dev/null)
    task_state=$(kubectl get kafkaconnector debezium-outbox-connector -n kafka \
        -o jsonpath='{.status.connectorStatus.tasks[0].state}' 2>/dev/null)

    if [[ "$conn_state" == "RUNNING" ]]; then
        _pass "Connector: $conn_state"
    else
        _fail "Connector: ${conn_state:-UNKNOWN}"
    fi

    if [[ "$task_state" == "RUNNING" ]]; then
        _pass "Task 0: $task_state"
    else
        _fail "Task 0: ${task_state:-UNKNOWN}"
        local trace
        trace=$(kubectl get kafkaconnector debezium-outbox-connector -n kafka \
            -o jsonpath='{.status.connectorStatus.tasks[0].trace}' 2>/dev/null \
            | grep -v "^\s*at " | head -3)
        [[ -n "$trace" ]] && _info "$trace"
        _info "Перезапустить: kubectl exec -n kafka debezium-connect-connect-0 -- \\"
        _info "  curl -s -X POST http://localhost:8083/connectors/debezium-outbox-connector/tasks/0/restart"
    fi

    # ── 5. End-to-end: событие → kafka ─────────────────────────────────────────
    _head "[ 5/5 ] End-to-end проверка"
    if [[ "$pg_ready" == "True" && "$task_state" == "RUNNING" ]]; then
        local before_offset
        before_offset=$(kubectl exec -n kafka kafka-cluster-kafka-0 -c kafka -- \
            bin/kafka-get-offsets.sh \
            --bootstrap-server localhost:9092 \
            --topic outbox.events.orders 2>/dev/null \
            | awk -F: '{sum+=$3} END{print sum+0}')

        # Вставляем тестовую запись
        local test_id="doctor-$(date +%s)"
        kubectl exec -n postgres "$pg_pod" -- \
            bash -c "PGPASSWORD='appuser_password_change_me' psql -h localhost \
            -U appuser -d appdb -c \
            \"INSERT INTO outbox (aggregate_type, aggregate_id, event_type, payload)
              VALUES ('orders','$test_id','DoctorCheck','{\\\"check\\\":\\\"ok\\\"}');\"" \
            &>/dev/null

        sleep 8

        local after_offset
        after_offset=$(kubectl exec -n kafka kafka-cluster-kafka-0 -c kafka -- \
            bin/kafka-get-offsets.sh \
            --bootstrap-server localhost:9092 \
            --topic outbox.events.orders 2>/dev/null \
            | awk -F: '{sum+=$3} END{print sum+0}')

        if (( after_offset > before_offset )); then
            _pass "Событие прошло в Kafka за ~8s (offset: $before_offset → $after_offset)"
        else
            _fail "Событие НЕ попало в Kafka за 8s (offset не изменился: $after_offset)"
            _info "Проверь логи Debezium: kubectl logs -n kafka debezium-connect-connect-0 | grep ERROR | tail -5"
        fi
    else
        _warn "E2E пропущен — PostgreSQL или коннектор недоступны"
    fi

    # ── итог ──────────────────────────────────────────────────────────────────
    _summary $ok $warn $fail
}

_summary() {
    local ok=$1 warn=$2 fail=$3
    echo
    echo -e "${BOLD}═══ Итог ════════════════════════════════════════════════${NC}"
    if   (( fail > 0 )); then
        echo -e "  ${RED}${BOLD}ПРОБЛЕМЫ НАЙДЕНЫ${NC}  ✔ $ok  ⚠ $warn  ✘ $fail"
        echo -e "  Подробности: ${CYAN}TROUBLESHOOTING.md${NC}"
    elif (( warn > 0 )); then
        echo -e "  ${YELLOW}${BOLD}ПРЕДУПРЕЖДЕНИЯ${NC}    ✔ $ok  ⚠ $warn"
    else
        echo -e "  ${GREEN}${BOLD}ВСЁ ХОРОШО${NC}        ✔ $ok"
    fi
    echo
}

# ── парсинг команды ───────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Использование: $(basename "$0") <команда> [флаги]

Команды:
  start              Запустить стенд (фаза 1: kafka + postgres)
    --with-ui          Включить kafka-ui
    --full             Включить kafka-ui + monitoring
  stop               Остановить minikube (данные сохраняются)
  destroy            Полное удаление (helm uninstall + minikube delete)
  status             Состояние подов и ресурсов
  build-image        (Пере)собрать docker-образ Debezium
  smoke-test         Тест end-to-end: вставить событие → прочитать из Kafka
  send <type> [event_type] '<json>'
                     Отправить произвольное событие в outbox
  tail [type] [n]    Показать последние N сообщений из топика (default: orders, 10)
  monitoring on|off  Включить / выключить мониторинг на живом стенде
  pf <сервис> [--bg] Port-forward: grafana, prometheus, kafka-ui, connect
                     --bg: запустить в фоне (не блокирует терминал)
  pf stop [сервис]   Остановить фоновый port-forward (все или конкретный)
  doctor             Диагностика всех компонентов + e2e проверка
EOF
}

main() {
    local cmd="${1:-}"
    shift || true

    case "$cmd" in
        start)
            local with_ui=false with_monitoring=false
            for arg in "$@"; do
                case "$arg" in
                    --with-ui)          with_ui=true ;;
                    --full)             with_ui=true; with_monitoring=true ;;
                    *)                  die "Неизвестный флаг: $arg" ;;
                esac
            done

            ensure_minikube
            ensure_namespaces
            ensure_helm_repos
            ensure_docker_image
            ensure_operators
            build_helm_deps
            deploy_stack "$with_ui" "$with_monitoring"
            wait_for_ready

            echo -e "\n${GREEN}${BOLD}Стенд запущен.${NC}"
            cmd_status
            ;;

        stop)       cmd_stop ;;
        destroy)    cmd_destroy ;;
        status)     cmd_status ;;
        build-image)
            eval "$(minikube docker-env)" 2>/dev/null \
                || die "minikube не запущен — запусти сначала './stand.sh start'"
            build_image
            ;;
        smoke-test)  cmd_smoke_test ;;
        send)        cmd_send "$@" ;;
        tail)        cmd_tail "$@" ;;
        monitoring)  cmd_monitoring "$@" ;;
        doctor)      cmd_doctor ;;
        pf)
            if [[ "${1:-}" == "stop" ]]; then
                cmd_pf_stop "${2:-}"
            else
                cmd_pf "$@"
            fi
            ;;
        help|--help|-h|"") usage ;;
        *) log_err "Неизвестная команда: $cmd"; usage; exit 1 ;;
    esac
}

main "$@"
