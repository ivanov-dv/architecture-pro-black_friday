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

// Создаёт hashed-индекс для shard key коллекции products.
db.products.createIndex({ _id: "hashed" })

// Создаёт hashed-индекс для shard key коллекции orders.
db.orders.createIndex({ customer_id: "hashed" })

// Создаёт hashed-индекс для shard key коллекции carts.
db.carts.createIndex({ owner_key: "hashed" })

// Шардирует products по хешу идентификатора товара.
sh.shardCollection("mobile_world.products", { _id: "hashed" })

// Шардирует orders по хешу идентификатора клиента.
sh.shardCollection("mobile_world.orders", { customer_id: "hashed" })

// Шардирует carts по хешу нормализованного владельца корзины.
sh.shardCollection("mobile_world.carts", { owner_key: "hashed" })

// Ускоряет поиск товаров по категории и диапазону цен.
db.products.createIndex({ category: 1, price: 1 })

// Ускоряет получение истории заказов клиента по дате.
db.orders.createIndex({ customer_id: 1, created_at: -1 })

// Ускоряет поиск активной корзины пользователя или гостя.
db.carts.createIndex({ owner_key: 1, status: 1 })

// Автоматически удаляет корзину после наступления expires_at.
db.carts.createIndex({ expires_at: 1 }, { expireAfterSeconds: 0 })
```
