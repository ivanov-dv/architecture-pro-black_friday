# Архитектурный документ

## Задание 7. Схемы коллекций MongoDB

### `products`

```javascript
{
  _id: ObjectId,
  name: String,
  category: String,
  price: Decimal128,
  stock_by_zone: [
    {
      geo_zone: String,
      quantity: Int32
    }
  ],
  attributes: {
    color: String,
    size: String
  }
}
```

### `orders`

```javascript
{
  _id: ObjectId,
  customer_id: ObjectId,
  created_at: Date,
  items: [
    {
      product_id: ObjectId,
      quantity: Int32,
      unit_price: Decimal128
    }
  ],
  status: String,
  total_amount: Decimal128,
  geo_zone: String
}
```

### `carts`

```javascript
{
  _id: ObjectId,
  owner_key: String,
  user_id: ObjectId,
  session_id: String,
  items: [
    {
      product_id: ObjectId,
      quantity: Int32
    }
  ],
  status: "active" | "ordered" | "abandoned",
  created_at: Date,
  updated_at: Date,
  expires_at: Date
}
```

`owner_key` имеет вид `user:<user_id>` для пользователя или `session:<session_id>` для гостя.

## Shard key

| Коллекция | Кандидаты | Выбранный shard key | Обоснование и риск |
|---|---|---|---|
| `products` | `_id`, `category`, `price` | `{ _id: "hashed" }` | Равномерно распределяет товары и обновления остатков. Поиск по категории выполняется на нескольких шардах. |
| `orders` | `_id`, `customer_id`, `created_at`, `geo_zone` | `{ customer_id: "hashed" }` | История клиента направляется на один шард. Поиск только по `_id` обращается ко всем шардам. |
| `carts` | `_id`, `user_id`, `session_id`, `owner_key` | `{ owner_key: "hashed" }` | Подходит и пользователям, и гостям. Слияние двух корзин может затронуть разные шарды. |

## Команды MongoDB

```javascript
// Включает шардирование для базы данных mobile_world.
sh.enableSharding("mobile_world")

// Переключает текущий контекст на базу mobile_world.
use mobile_world

// Создаёт индекс для shard key.
db.products.createIndex({ _id: "hashed" })
db.orders.createIndex({ customer_id: "hashed" })
db.carts.createIndex({ owner_key: "hashed" })

// Шардирует коллекцию по хешу идентификатора.
sh.shardCollection("mobile_world.products", { _id: "hashed" })
sh.shardCollection("mobile_world.orders", { customer_id: "hashed" })
sh.shardCollection("mobile_world.carts", { owner_key: "hashed" })

// Создание индексов для ускорения выполнения запросов.
db.products.createIndex({ category: 1, price: 1 })
db.orders.createIndex({ customer_id: 1, created_at: -1 })
db.carts.createIndex({ owner_key: 1, status: 1 })

// Удаление после наступления expires_at.
db.carts.createIndex({ expires_at: 1 }, { expireAfterSeconds: 0 })
```

## Задание 8. «Горячие» шарды

### Метрики

| Метрика |
|---|
| CPU, disk IOPS и задержка диска |
| Количество операций и p95 времени запросов |
| Количество документов, объём данных |
| Отставание secondary-реплик |

### Устранение дисбаланса

- После обнаружения горячей категории использовать для `products` составной shard key `{ category: 1, _id: "hashed" }`. Поле `category` позволяет настроить зоны, а хешированный `_id` распределяет товары одной категории между шардами.
- Держать MongoDB Balancer включённым. Он автоматически перемещает данные между шардами.
- Создать для категории «Электроника» зону `electronics_zone` и включить в неё минимум два выделенных шарда. Один шард в зоне снова станет горячим.
- Использовать индекс `{ category: 1, price: 1 }` для запросов к популярным категориям.
- Использовать `moveChunk` только для ручного устранения дисбаланса. Balancer распределяет объём данных, но не учитывает количество запросов.

### Команды MongoDB

```javascript
// Показывает количество документов, чанки и объём products на каждом шарде.
db.products.getShardDistribution()

// Показывает общую конфигурацию шардирования и распределение chunks.
sh.status()

// Проверяет, сбалансирована ли коллекция products.
sh.balancerCollectionStatus("mobile_world.products")

// Показывает текущее состояние балансировщика.
db.adminCommand({ balancerStatus: 1 })

// Включает автоматическое перераспределение данных.
sh.startBalancer()

// Создаёт индекс для нового составного shard key.
db.products.createIndex({ category: 1, _id: "hashed" })

// Меняет shard key, чтобы категории можно было связывать с зонами.
db.adminCommand({
  reshardCollection: "mobile_world.products",
  key: { category: 1, _id: "hashed" }
})

// Добавляет первый выделенный шард в зону популярной категории.
sh.addShardToZone("shard2", "electronics_zone")

// Добавляет второй выделенный шард в зону популярной категории.
sh.addShardToZone("shard3", "electronics_zone")

// Закрепляет товары категории «Электроника» за выделенной зоной.
sh.updateZoneKeyRange(
  "mobile_world.products",
  { category: "Электроника", _id: MinKey },
  { category: "Электроника", _id: MaxKey },
  "electronics_zone"
)

// Вручную перемещает chunk с указанным товаром на shard2.
sh.moveChunk(
  "mobile_world.products",
  { category: "Электроника", _id: productId },
  "shard2"
)
```

## Задание 9. Чтение с реплик

| Коллекция | Операция чтения | Узел | Допустимая задержка | Обоснование |
|---|---|---|---:|---|
| `products` | Каталог, фильтрация по категории и цене | Secondary | До 5 секунд | Небольшая устарелость допустима |
| `products` | Описание товара | Secondary | До 5 секунд | Описание меняется редко |
| `products` | Цена и остаток перед оформлением заказа | Primary | 0 секунд | Иначе возможна продажа недоступного товара |
| `orders` | История завершённых заказов | Secondary | До 5 секунд | Завершённые заказы почти не меняются |
| `orders` | Только что созданный заказ | Primary | 0 секунд | Пользователь должен сразу увидеть заказ |
| `orders` | Текущий статус заказа | Primary | 0 секунд | Нельзя показывать устаревший статус |
| `carts` | Получение активной корзины | Primary | 0 секунд | Корзина часто изменяется |
| `carts` | Чтение корзин при слиянии | Primary | 0 секунд | Нельзя потерять добавленные или вернуть удалённые товары |

### Настройка консистентности

```text
Некритичное чтение:
readPreference = secondaryPreferred
readConcern = majority

Критичное чтение:
readPreference = primary
readConcern = majority

Запись:
writeConcern = majority
```

### Контроль задержки репликации

```javascript
// Получает состояние участников replica set.
const status = rs.status()

// Находит Primary, с которым сравниваются Secondary.
const primary = status.members.find(member => member.stateStr === "PRIMARY")

// Рассчитывает задержку каждой Secondary в секундах.
status.members
  .filter(member => member.stateStr === "SECONDARY")
  .map(member => ({
    host: member.name,
    lag_seconds: (primary.optimeDate - member.optimeDate) / 1000
  }))
```

Проверка выполняется фоново на каждом replica set, а не перед каждым запросом. Если последнее измеренное значение больше 5 секунд, некритичное чтение временно направляется на Primary. Для операций сразу после записи Primary используется всегда.

## Задание 10. Миграция на Cassandra

### 10.1. Выбор данных для переноса

| Данные | Перенос в Cassandra | Обоснование |
|---|---|---|
| Заказы и текущий статус | Нет | Создание заказа должно выполняться в одной транзакции со списанием остатков |
| Товары и остатки | Нет | Перед продажей требуется проверить актуальный остаток и выполнить условное списание |
| История заказов | Да | Записывается после успешного создания заказа и хорошо масштабируется по клиентам и периодам |
| Корзины | Да | Не подтверждают наличие товара, хранятся по ключу владельца и могут удаляться по TTL |

### 10.2. Модель данных Cassandra

| Таблица | Partition key | Clustering key | Назначение |
|---|---|---|---|
| order_history | (customer_id, month_bucket) | created_at, order_id | История заказов клиента за месяц |
| carts | owner_key | — | Получение текущей корзины пользователя или гостя |

```cql
-- Выбирает пространство ключей, в котором будут созданы таблицы.
USE mobile_world;

-- Создаёт таблицу истории заказов клиента с разбиением по месяцам.
CREATE TABLE order_history (
    customer_id uuid,
    month_bucket date,
    created_at timestamp,
    order_id uuid,
    status text,
    total_amount decimal,
    geo_zone text,
    PRIMARY KEY ((customer_id, month_bucket), created_at, order_id)
) WITH CLUSTERING ORDER BY (created_at DESC);

-- Создаёт таблицу текущих корзин пользователей и гостей.
CREATE TABLE carts (
    owner_key text PRIMARY KEY,
    user_id uuid,
    session_id text,
    items map<uuid, int>,
    status text,
    created_at timestamp,
    updated_at timestamp,
    expires_at timestamp
);
```

Составной partition key `(customer_id, month_bucket)` и ключ `owner_key` хешируются Cassandra и распределяют партиции между узлами. Поле `month_bucket` ограничивает историю одним месяцем и предотвращает появление слишком большой партиции у активного клиента.

### 10.3. Восстановление целостности данных

| Сущность | Hinted Handoff | Read Repair | Anti-Entropy Repair | Обоснование |
|---|---|---|---|---|
| order_history | Да | NONE | Да | История почти не изменяется, поэтому важнее низкая задержка чтения |
| carts | Да | BLOCKING | Да | Пользователь должен видеть последние изменения своей корзины |
