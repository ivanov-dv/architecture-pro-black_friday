# MongoDB sharding, replication and caching

Проект запускает `pymongo-api`, Redis и шардированный кластер MongoDB. Каждый из двух шардов состоит из трёх узлов: одного PRIMARY и двух SECONDARY.

## Сервисы

| Сервис | Порт MongoDB | Replica set |
|---|---:|---|
| `configSrv` | 27017 | `config_server` |
| `shard1-1` | 27018 | `shard1` |
| `shard1-2` | 27018 | `shard1` |
| `shard1-3` | 27018 | `shard1` |
| `shard2-1` | 27019 | `shard2` |
| `shard2-2` | 27019 | `shard2` |
| `shard2-3` | 27019 | `shard2` |
| `mongos` | 27020 | — |
| `redis` | 6379 | — |
| `pymongo-api` | 8080 | — |

База данных называется `somedb`, коллекция — `helloDoc`. Коллекция шардируется по хешированному ключу `_id`.

Приложение подключается к Redis по адресу `redis://redis:6379`. Эндпоинт `/<collection_name>/users` кешируется на 60 секунд.

## Автоматическая инициализация

Из директории `sharding-repl-cache` выполните:

```shell
./scripts/init-sharding-repl-cache.sh
```

Скрипт:

1. Запускает сервер конфигурации и все шесть узлов шардов.
2. Инициализирует replica set `config_server`, `shard1` и `shard2`.
3. Ждёт появления одного PRIMARY и двух SECONDARY в каждом шарде.
4. Запускает Redis и ждёт ответа `PONG`.
5. Запускает `mongos` и `pymongo-api`.
6. Добавляет оба replica set в кластер как шарды.
7. Включает шардирование `somedb.helloDoc` и добавляет 1000 документов.

Скрипт можно запускать повторно: replica set, шарды и документы не дублируются.

## Ручная настройка репликации

Запустите сервер конфигурации и все узлы шардов:

```shell
docker compose up -d configSrv shard1-1 shard1-2 shard1-3 shard2-1 shard2-2 shard2-3
```

Инициализируйте сервер конфигурации:

```shell
docker compose exec -T configSrv mongosh --port 27017 --quiet <<'EOF'
rs.initiate({
  _id: "config_server",
  configsvr: true,
  members: [{ _id: 0, host: "configSrv:27017" }]
});
EOF
```

Настройте репликацию первого шарда:

```shell
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<'EOF'
rs.initiate({
  _id: "shard1",
  members: [
    { _id: 0, host: "shard1-1:27018" },
    { _id: 1, host: "shard1-2:27018" },
    { _id: 2, host: "shard1-3:27018" }
  ]
});
EOF
```

Настройте репликацию второго шарда:

```shell
docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<'EOF'
rs.initiate({
  _id: "shard2",
  members: [
    { _id: 0, host: "shard2-1:27019" },
    { _id: 1, host: "shard2-2:27019" },
    { _id: 2, host: "shard2-3:27019" }
  ]
});
EOF
```

Дождитесь появления PRIMARY и двух SECONDARY в каждом шарде, затем запустите Redis, роутер и приложение:

```shell
docker compose up -d redis mongos pymongo-api
```

Добавьте replica set как шарды, включите шардирование и заполните коллекцию:

```shell
docker compose exec -T mongos mongosh --port 27020 --quiet <<'EOF'
sh.addShard("shard1/shard1-1:27018,shard1-2:27018,shard1-3:27018");
sh.addShard("shard2/shard2-1:27019,shard2-2:27019,shard2-3:27019");
sh.enableSharding("somedb", "shard1");
sh.shardCollection("somedb.helloDoc", { _id: "hashed" });

use somedb
for (let i = 0; i < 1000; i += 1) {
  db.helloDoc.insertOne({ age: i, name: `ly${i}` });
}
EOF
```

## Проверка

Проверьте состояние контейнеров:

```shell
docker compose ps
```

Проверьте общее количество документов и информацию о кластере через приложение:

```shell
curl --silent http://localhost:8080/helloDoc/count
curl --silent http://localhost:8080/
```

Swagger доступен по адресу <http://localhost:8080/docs>.

Проверьте количество документов в первом шарде:

```shell
docker compose exec -T shard1-1 mongosh \
  'mongodb://shard1-1:27018,shard1-2:27018,shard1-3:27018/?replicaSet=shard1' \
  --quiet --eval 'db.getSiblingDB("somedb").helloDoc.countDocuments({})'
```

Проверьте количество документов во втором шарде:

```shell
docker compose exec -T shard2-1 mongosh \
  'mongodb://shard2-1:27019,shard2-2:27019,shard2-3:27019/?replicaSet=shard2' \
  --quiet --eval 'db.getSiblingDB("somedb").helloDoc.countDocuments({})'
```

Сумма документов на двух шардах должна совпадать с результатом API и быть не меньше 1000.

Проверьте количество и состояния реплик первого шарда:

```shell
docker compose exec -T shard1-1 mongosh --port 27018 --quiet \
  --eval 'rs.status().members.map((member) => ({ name: member.name, state: member.stateStr }))'
```

Проверьте количество и состояния реплик второго шарда:

```shell
docker compose exec -T shard2-1 mongosh --port 27019 --quiet \
  --eval 'rs.status().members.map((member) => ({ name: member.name, state: member.stateStr }))'
```

В каждом результате должно быть три узла: один `PRIMARY` и два `SECONDARY`.

## Проверка кеширования

Убедитесь, что в ответе корневого эндпоинта поле `cache_enabled` равно `true`:

```shell
curl --silent http://localhost:8080/
```

Очистите Redis, чтобы следующий запрос гарантированно выполнился без кеша:

```shell
docker compose exec -T redis redis-cli FLUSHDB
```

Сразу после очистки выполните два одинаковых запроса подряд:

```shell
curl --output /dev/null --silent \
  --write-out 'First: %{time_total}s\n' \
  http://localhost:8080/helloDoc/users

curl --output /dev/null --silent \
  --write-out 'Second: %{time_total}s\n' \
  http://localhost:8080/helloDoc/users
```

Первый запрос занимает около одной секунды. Второй и последующие запросы в течение 60 секунд должны выполняться быстрее `0.1` секунды.
