#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_DIR}"

wait_for_mongo() {
  local service_name="$1"
  local mongo_port="$2"

  for _ in $(seq 1 60); do
    if docker compose exec -T "${service_name}" \
      mongosh --port "${mongo_port}" --quiet \
      --eval 'db.adminCommand({ ping: 1 }).ok' 2>/dev/null | grep -qx '1'; then
      return 0
    fi
    sleep 1
  done

  echo "MongoDB service ${service_name}:${mongo_port} is not ready" >&2
  return 1
}

wait_for_primary() {
  local service_name="$1"
  local mongo_port="$2"

  for _ in $(seq 1 60); do
    if docker compose exec -T "${service_name}" \
      mongosh --port "${mongo_port}" --quiet \
      --eval 'db.hello().isWritablePrimary' 2>/dev/null | grep -qx 'true'; then
      return 0
    fi
    sleep 1
  done

  echo "Replica set on ${service_name}:${mongo_port} has no primary" >&2
  return 1
}

wait_for_api() {
  for _ in $(seq 1 60); do
    if curl --silent --fail --output /dev/null \
      http://localhost:8080/helloDoc/count; then
      return 0
    fi
    sleep 1
  done

  echo "pymongo-api is not ready on http://localhost:8080" >&2
  return 1
}

echo "Starting config server and shards..."
docker compose up -d configSrv shard1-1 shard2-1

wait_for_mongo configSrv 27017
wait_for_mongo shard1-1 27018
wait_for_mongo shard2-1 27019

echo "Initializing config server replica set..."
docker compose exec -T configSrv mongosh --port 27017 --quiet <<'EOF'
try {
  const replicaSetStatus = rs.status();
} catch (error) {
  if (error.code === 94 || error.codeName === "NotYetInitialized") {
    rs.initiate({
      _id: "config_server",
      configsvr: true,
      members: [{ _id: 0, host: "configSrv:27017" }]
    });
  } else {
    throw error;
  }
}
EOF

echo "Initializing shard1 replica set..."
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<'EOF'
try {
  const replicaSetStatus = rs.status();
} catch (error) {
  if (error.code === 94 || error.codeName === "NotYetInitialized") {
    rs.initiate({
      _id: "shard1",
      members: [{ _id: 0, host: "shard1-1:27018" }]
    });
  } else {
    throw error;
  }
}
EOF

echo "Initializing shard2 replica set..."
docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<'EOF'
try {
  const replicaSetStatus = rs.status();
} catch (error) {
  if (error.code === 94 || error.codeName === "NotYetInitialized") {
    rs.initiate({
      _id: "shard2",
      members: [{ _id: 0, host: "shard2-1:27019" }]
    });
  } else {
    throw error;
  }
}
EOF

wait_for_primary configSrv 27017
wait_for_primary shard1-1 27018
wait_for_primary shard2-1 27019

echo "Starting mongos and pymongo-api..."
docker compose up -d mongos pymongo-api
wait_for_mongo mongos 27020

echo "Adding shards and configuring somedb.helloDoc..."
docker compose exec -T mongos mongosh --port 27020 --quiet <<'EOF'
const adminDb = db.getSiblingDB("admin");
const configDb = db.getSiblingDB("config");
const shardIds = adminDb.runCommand({ listShards: 1 }).shards.map((shard) => shard._id);

if (!shardIds.includes("shard1")) {
  const addShard1Result = sh.addShard("shard1/shard1-1:27018");
}

if (!shardIds.includes("shard2")) {
  const addShard2Result = sh.addShard("shard2/shard2-1:27019");
}

if (configDb.databases.findOne({ _id: "somedb" }) === null) {
  const enableShardingResult = sh.enableSharding("somedb", "shard1");
}

if (configDb.collections.findOne({ _id: "somedb.helloDoc" }) === null) {
  const shardCollectionResult = sh.shardCollection(
    "somedb.helloDoc",
    { _id: "hashed" }
  );
}

const helloDoc = db.getSiblingDB("somedb").helloDoc;
const operations = [];

for (let i = 0; i < 1000; i += 1) {
  operations.push({
    updateOne: {
      filter: { _id: i },
      update: { $setOnInsert: { age: i, name: `ly${i}` } },
      upsert: true
    }
  });
}

const bulkWriteResult = helloDoc.bulkWrite(operations, { ordered: false });
print(`Documents in somedb.helloDoc: ${helloDoc.countDocuments({})}`);
EOF

wait_for_api
echo "Sharding initialization completed."
