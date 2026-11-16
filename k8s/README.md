# hw6 — миграция в k3s

Ветка: `week6`. Домен: `hw3.novik.tech`. Docker Hub: `eugenemns`.
Манифесты и модуль `/ready` взяты из официального `hw6.patch`; в манифестах
заменены только домен, Docker Hub username и email ACME.

## Состояние на 16 ноября 2026

- Заготовка применена; backend собирается, frontend проходит TypeScript-проверки.
- Проверены `/ready` при доступной и недоступной БД, восстановление и независимость `/health`.
- Действующее приложение из `week5` прошло `make e2e-deployed`: **16/16**.
- Резервная копия на VPS: `/home/deploy/backups/hw6-20261116T154221Z/`.
  В ней `todo.sql`, `nginx-sites.tar.gz`, `compose-config.tar.gz`, `images.txt`.
- Установка k3s ожидает административного доступа: `deploy` требует пароль sudo,
  а вход root по имеющимся SSH-ключам не проходит. Кластер ещё не установлен.
- Действующий Compose-стек, nginx и остальные приложения продолжают работать.
- Новая ветка ещё не отправлена на GitHub. Проверки после миграции ещё не выполнены.

## Установка кластера

Проверенный скрипт загружен на VPS: `~/myapp-hw6/bootstrap-k3s.sh`.
После восстановления sudo выполнить со своей машины:

```bash
ssh -t -i ~/.ssh/github_actions deploy@57.131.194.112 \
  'sudo bash ~/myapp-hw6/bootstrap-k3s.sh'
```

Скрипт устанавливает `v1.35.10+k3s1` без Traefik, добавляет публичный IP в TLS SAN,
настраивает UFW и kubeconfig пользователя deploy. Версия Kubernetes 1.35 входит
в [таблицу совместимости ingress-nginx 1.15.1](https://github.com/kubernetes/ingress-nginx#supported-versions-table).
Скрипт оставляет текущие Docker-контейнеры и системный nginx работающими.

До переключения портов 80/443 необходимо сохранить существующие маршруты
`bot.novik.tech` (`/developer/api/health`, `/profile2/api/health`, `/profile3/api/health`),
перенаправление `novik.tech` и доступ к Grafana. Простое отключение nginx из
методички затронет эти сайты.

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

После готовности кластера добавить в Secrets репозитория `KUBE_CONFIG`:
base64 kubeconfig с `server: https://57.131.194.112:6443`.
Не выводить kubeconfig в чат или логи. Это административные учётные данные кластера.

Push в `week6` запускает TypeScript-проверки, сборку и публикацию backend
`sha-<commit>` и `latest`, применение backend через `envsubst`, ожидание rollout,
внешние smoke/readiness/SHA-проверки и Telegram-уведомление. Frontend переиспользуется.
Push выполнять после готовности кластера и настройки секрета.

Финальная проверка: зелёный workflow, `/api/health` с SHA коммита `week6`,
`/api/ready` → 200, Certificate `app-tls` Ready, все реплики доступны,
PVC Bound, сохранность данных и повторный `make e2e-deployed`.
`k8s/optional/` содержит заготовки self-study, пока они не развёрнуты.
