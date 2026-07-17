# MongoDB sharding

Проект запускает `pymongo-api` и шардированный кластер MongoDB из двух шардов.

## Сервисы

| Сервис | Порт | Назначение |
|---|---:|---|
| `configSrv` | 27017 | Сервер конфигурации MongoDB |
| `shard1-1` | 27018 | Первый шард, replica set `shard1` |
| `shard2-1` | 27019 | Второй шард, replica set `shard2` |
| `mongos` | 27020 | Роутер MongoDB |
| `pymongo-api` | 8080 | API приложения |

База данных называется `somedb`, коллекция — `helloDoc`. Коллекция шардируется по хешированному ключу `_id`.

## Автоматическая инициализация

Из директории `mongo-sharding` выполните:

```shell
./scripts/init-sharding.sh
```

Скрипт выполняет следующие действия:

1. Запускает `configSrv`, `shard1-1` и `shard2-1`.
2. Инициализирует replica set `config_server`, `shard1` и `shard2`.
3. Запускает `mongos` и `pymongo-api`.
4. Добавляет оба шарда в кластер.
5. Включает шардирование базы `somedb` и коллекции `helloDoc`.
6. Добавляет в коллекцию 1000 документов.

Скрипт можно запускать повторно: уже созданные replica set, шарды и документы не дублируются.

## Ручная инициализация

Сначала запустите сервер конфигурации и шарды:

```shell
docker compose up -d configSrv shard1-1 shard2-1
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

Инициализируйте первый шард:

```shell
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<'EOF'
rs.initiate({
  _id: "shard1",
  members: [{ _id: 0, host: "shard1-1:27018" }]
});
EOF
```

Инициализируйте второй шард:

```shell
docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<'EOF'
rs.initiate({
  _id: "shard2",
  members: [{ _id: 0, host: "shard2-1:27019" }]
});
EOF
```

После выбора PRIMARY на всех трёх replica set запустите роутер и приложение:

```shell
docker compose up -d mongos pymongo-api
```

Добавьте шарды, включите шардирование и заполните коллекцию:

```shell
docker compose exec -T mongos mongosh --port 27020 --quiet <<'EOF'
sh.addShard("shard1/shard1-1:27018");
sh.addShard("shard2/shard2-1:27019");
sh.enableSharding("somedb", "shard1");
sh.shardCollection("somedb.helloDoc", { _id: "hashed" });

use somedb
for (let i = 0; i < 1000; i += 1) {
  db.helloDoc.insertOne({ age: i, name: `ly${i}` });
}
EOF
```

## Проверка

Состояние контейнеров:

```shell
docker compose ps
```

Общая информация о кластере и количество документов через приложение:

```shell
curl --silent http://localhost:8080/
curl --silent http://localhost:8080/helloDoc/count
```

Swagger доступен по адресу <http://localhost:8080/docs>.

Количество документов на первом шарде:

```shell
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<'EOF'
use somedb
db.helloDoc.countDocuments()
EOF
```

Количество документов на втором шарде:

```shell
docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<'EOF'
use somedb
db.helloDoc.countDocuments()
EOF
```

Сумма документов на двух шардах должна совпадать с результатом `http://localhost:8080/helloDoc/count` и быть не меньше 1000.
