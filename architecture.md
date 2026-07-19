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

- Использовать для `products` shard key `{ _id: "hashed" }`, чтобы товары популярных категорий распределялись между шардами.
- Держать MongoDB Balancer включённым. Он автоматически перемещает данные между шардами.
- Если коллекция была распределена по `category`, изменить shard key на `{ _id: "hashed" }` через `reshardCollection`.
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

// Меняет неудачный shard key на hashed-ключ по идентификатору товара.
db.adminCommand({
  reshardCollection: "mobile_world.products",
  key: { _id: "hashed" }
})

// Вручную перемещает chunk с указанным товаром на shard2.
sh.moveChunk(
  "mobile_world.products",
  { _id: productId },
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
