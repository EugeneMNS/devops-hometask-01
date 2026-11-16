# hw6 — миграция в k3s

Ветка: `week6`. Домен: `hw3.novik.tech`. Docker Hub: `eugenemns`.
Манифесты и модуль `/ready` взяты из официального `hw6.patch`; в манифестах
заменены только домен, Docker Hub username и email ACME.

## Состояние на 16 ноября 2026

- k3s `v1.35.10+k3s1`: нода Ready, CoreDNS, Metrics Server и local-path работают.
- Postgres с PVC и по две реплики backend/frontend запущены.
- Backend-образ `eugenemns/todo-back:hw6-3e814ec` собран для linux/amd64 и опубликован.
- С реальной БД проверены `/ready` → 200/503, независимость `/health`, восстановление
  без перезапуска backend и исключение `/ready` из метрик.
- Проверено сохранение todo после пересоздания `postgres-0`.
- Внутри ingress проверены API rewrite, SPA-ссылки и сохранение прежних маршрутов.
- Резервная копия до миграции: `/home/deploy/backups/hw6-20261116T154221Z/`.
- Публичные маршруты переключены на ingress; все четыре сертификата Ready.
- Финальная копия БД: `/home/deploy/backups/hw6-cutover-20261116T170650Z/`.
- Прежние back/front/db остановлены, старый Docker volume БД сохранён.
- После переключения публичные e2e прошли: **16/16**.
- CI запускается при отправке ветки `week6` и проверяет SHA развёрнутого backend.

## Установка кластера

Проверенный скрипт загружен на VPS: `~/myapp-hw6/bootstrap-k3s.sh`.
Для первоначальной установки выполнить со своей машины:

```bash
ssh -t -i ~/.ssh/github_actions deploy@57.131.194.112 \
  'sudo bash ~/myapp-hw6/bootstrap-k3s.sh'
```

Скрипт устанавливает `v1.35.10+k3s1` без Traefik, добавляет публичный IP в TLS SAN,
настраивает UFW и kubeconfig пользователя deploy. Версия Kubernetes 1.35 входит
в [таблицу совместимости ingress-nginx 1.15.1](https://github.com/kubernetes/ingress-nginx#supported-versions-table).
Скрипт оставляет текущие Docker-контейнеры и системный nginx работающими.

`ops/legacy-routes.yaml` сохраняет существующие маршруты `bot.novik.tech`,
перенаправление `novik.tech` и Grafana. Контейнеры ботов продолжают работать в Docker;
прокси в k3s обращается к их прежним loopback-портам. `profile3` был недоступен
до миграции (HTTP 502), его маршрут сохранён.

### Совместимость Ubuntu 26.04

На ядре `7.0.0-43-generic` обнаружена регрессия AppArmor: `gosu` в новом Postgres
зависал при смене UID. В профиль containerd добавлены только точные правила
`signal` и `ptrace` для `cri-containerd.apparmor.d//&unconfined` из принятого
[containerd PR #14487](https://github.com/containerd/containerd/pull/14487).
Базовый профиль взят из containerd `v2.2.10`; исходный и исправленный варианты — в `ops/`.

`scripts/fix-containerd-apparmor.sh` проверяет изменение, сохраняет предыдущий
профиль, загружает исправление и проверяет передачу сигналов в confined-процессе.
AppArmor остаётся в enforce, host sysctl не меняется. При обновлении k3s/containerd
этот локальный override нужно пересмотреть с учётом штатного исправления.

### Переключение публичного трафика

Helm charts: ingress-nginx `4.15.1`, cert-manager `v1.21.3`; values в `ops/`.
Для проверки ingress первоначально установлен с Service типа ClusterIP и доступен
через локальный port-forward. Временная аннотация `ssl-redirect=false` нужна только
для этой внутренней проверки и удаляется скриптом переключения.

`scripts/cutover-k3s.sh` останавливает запись в прежний backend, делает финальный
pg_dump, восстанавливает его в Postgres k3s, сверяет число записей, проверяет rollout,
передаёт 80/443 ingress, ждёт четыре сертификата и фактическую готовность TLS/SNI,
затем проверяет прежние маршруты.
При ошибке предусмотрен возврат прежнего nginx и Compose-приложения; этот откат
проверен при первоначальной задержке загрузки сертификатов в ingress. Старый том
Postgres сохраняется. Контейнеры ботов и мониторинга этот скрипт не останавливает.

Ingress-nginx выбран по требованию учебной методички. У проекта завершена поддержка:
[официальное уведомление](https://github.com/kubernetes/ingress-nginx#ingress-nginx-retirement).
Для длительной эксплуатации нужен поддерживаемый ingress-контроллер.

## Секреты и первый деплой

`secret.yaml` содержит локально сгенерированный пароль БД, права файла `0600`.
`dockerhub-secret.yaml` содержит пустой auths: оба репозитория образов публичные,
токен для скачивания не нужен. Оба файла игнорируются Git; в репозитории только примеры.

Применять файлы явно, в порядке из методички. Команда `kubectl apply -f k8s/`
подхватит также шаблоны Secret и необработанный backend-манифест:

```bash
kubectl apply -f k8s/configmap.yaml -f k8s/app-config.yaml
kubectl apply -f k8s/secret.yaml -f k8s/dockerhub-secret.yaml
kubectl apply -f k8s/postgres.yaml -f k8s/frontend.yaml

# Сначала собрать backend с /ready и опубликовать образ либо импортировать
# локально собранный образ в containerd k3s. Старый образ week5 не содержит /ready.
export IMAGE=eugenemns/todo-back:latest APP_VERSION=manual
envsubst '${IMAGE} ${APP_VERSION}' < k8s/backend.yaml | kubectl apply -f -
kubectl rollout status deployment/backend --timeout=300s
```

Перед переключением трафика восстановить `todo.sql` в Postgres кластера;
установить ingress-nginx и cert-manager, применить ClusterIssuer и Ingress,
проверить выдачу сертификата и сохранение данных после пересоздания postgres-0.

## CI/CD

`.github/workflows/deploy-k8s.yml` использует существующие `DOCKER_USER`,
`DOCKER_PASS`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` и переменную `VITE_API_URL`.
Compose workflow переименован в `deploy.yml.disabled`.

В GitHub Secrets добавлен `KUBE_CONFIG`: base64 файла `k3s-ci.kubeconfig` с
`server: https://57.131.194.112:6443`. Он использует отдельный ServiceAccount
`github-deployer` из `ops/github-deployer.yaml`, который может читать/обновлять
только Deployment и Service с именем `backend` в default. Доступа к Secret, нодам
и другим приложениям нет; права и rollout проверены фактически.

`scripts/create-ci-kubeconfig.py` создаёт этот файл с правами 0600 без вывода токена.
Администраторский `k3s-hw6.kubeconfig` используется локально и в GitHub не передаётся.
Все `*.kubeconfig` исключены из Git. Если backend Deployment/Service удалены,
их первоначальное создание выполняет администратор, затем CI продолжает обновление.

Push в `week6` запускает TypeScript-проверки, сборку и публикацию backend
`sha-<commit>` и `latest`, применение backend через `envsubst`, ожидание rollout,
внешние smoke/readiness/SHA-проверки и Telegram-уведомление. Frontend переиспользуется.
Push выполнять после готовности кластера и настройки секрета.

Финальная проверка: зелёный workflow, `/api/health` с SHA коммита `week6`,
`/api/ready` → 200, Certificate `app-tls` Ready, все реплики доступны,
PVC Bound, сохранность данных и повторный `make e2e-deployed`.
`k8s/optional/` содержит заготовки self-study, пока они не развёрнуты.
