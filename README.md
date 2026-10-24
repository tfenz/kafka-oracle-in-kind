# kafka-oracle-in-kind

Local test environment for Oracle → Kafka Change Data Capture (CDC) experiments.
It spins up a [Kind](https://kind.sigs.k8s.io/) cluster with:

| Component | Details |
|-----------|---------|
| [Strimzi](https://strimzi.io/) operator | `1.3.0`, namespace `kafka` |
| Kafka cluster `cdc-cluster` | Kafka `4.3.1`, KRaft, 1 dual-role node |
| [AKHQ](https://akhq.io/) | `0.28.0`, Kafka web UI, namespace `kafka` |
| Oracle Database | `19.3.0.0` Enterprise, namespace `oracle`, CDB `ORCLCDB`, PDB `ORCLPDB1` |

The CDC pipeline itself (Debezium `KafkaConnector` + [OpenLogReplicator](https://github.com/bersler/OpenLogReplicator)) is **not** part of this repo.
The database is prepared for it, though:

- `ARCHIVELOG` mode, archives in `/opt/oracle/oradata/fast_recovery_area`
- `FORCE LOGGING` and minimal database-level supplemental logging
- online redo logs + archives live on PVC `oracle/oracle-oradata`. Kind runs a single node, so an OpenLogReplicator pod can mount the same claim (read-only).
- demo schema: `DEMO.CUSTOMERS` in `ORCLPDB1`

See [`k8s/oracle/setup/01-cdc-prep.sh`](k8s/oracle/setup/01-cdc-prep.sh). CDC-specific users/grants and table-level supplemental logging are left to the CDC setup.

## Prerequisites

- `kind`, `kubectl`, `curl`
- `docker` or `podman` (podman is used automatically when docker is missing)
- ~8 GB RAM free for the cluster, ~20 GB disk for the Oracle image + datafiles

### Oracle image

The Oracle image is pulled from the Oracle Container Registry, which requires a free Oracle account:

1. Sign in at <https://container-registry.oracle.com>, open **Database → enterprise** and accept the license.
2. Generate an auth token (profile menu → *Auth Token*).
3. Use **one** of these options:
   - pull it locally (it's loaded into Kind, so you only download it once):
     ```bash
     podman login container-registry.oracle.com
     podman pull container-registry.oracle.com/database/enterprise:19.3.0.0
     ```
   - or let the Kind node pull it through an image pull secret:
     ```bash
     export ORACLE_REGISTRY_USER='you@example.com'
     export ORACLE_REGISTRY_TOKEN='<auth token>'
     ```

## Usage

```bash
./scripts/up.sh                # Kind + Strimzi + Kafka + AKHQ + Oracle
./scripts/up.sh --skip-oracle  # Kafka + AKHQ, without Oracle
./scripts/up.sh --no-wait      # don't wait for Kafka/AKHQ/Oracle readiness
./scripts/down.sh              # delete the cluster (all data is lost)
```

`up.sh` is idempotent, so you can re-run it to apply changes.
On first start Oracle creates the database, which takes about **15–30 minutes**. Follow progress with:

```bash
kubectl --context kind-kafka-oracle -n oracle logs -f oracle-0
```

### Configuration (environment variables)

| Variable | Default |
|----------|---------|
| `CLUSTER_NAME` | `kafka-oracle` |
| `STRIMZI_VERSION` | `1.3.0` |
| `ORACLE_IMAGE` | `container-registry.oracle.com/database/enterprise:19.3.0.0` |
| `ORACLE_PWD` | `OraclePwd_123` (SYS / SYSTEM / PDBADMIN) |
| `DEMO_PWD` | `demo` |

## Endpoints

| | In-cluster | From host |
|-|-----------|-----------|
| Kafka | `cdc-cluster-kafka-bootstrap.kafka.svc:9092` | `127.0.0.1:9092` |
| Oracle PDB | `oracle.oracle.svc:1521/ORCLPDB1` | `127.0.0.1:1521/ORCLPDB1` |
| Oracle CDB | `oracle.oracle.svc:1521/ORCLCDB` | `127.0.0.1:1521/ORCLCDB` |

Use `127.0.0.1` rather than `localhost`: Kind's port mappings only listen on IPv4.

### AKHQ web UI

AKHQ connects to the internal Kafka listener and is deployed even with `--skip-oracle`.
To open it, keep this command running and browse to <http://127.0.0.1:8080>:

```bash
kubectl --context kind-kafka-oracle -n kafka port-forward --address 127.0.0.1 svc/akhq 8080:8080
```

AKHQ has no authentication in this local test setup. Its Service is cluster-internal;
the port-forward binds only to the loopback address. No cluster recreation is needed.
Kafka Connect and Schema Registry connections are not configured.

### Client examples

```bash
# Kafka from the host
echo hello | podman run -i --rm --network host docker.io/edenhill/kcat:1.7.1 -b 127.0.0.1:9092 -P -t smoke
podman run --rm --network host docker.io/edenhill/kcat:1.7.1 -b 127.0.0.1:9092 -C -t smoke -e

# SQL*Plus inside the Oracle pod
kubectl --context kind-kafka-oracle -n oracle exec -it oracle-0 -- sqlplus demo/demo@//localhost:1521/ORCLPDB1
```

## Layout

```
kind/cluster.yaml            Kind cluster + host port mappings (1521, 9092, 9093)
k8s/kafka/kafka.yaml         KafkaNodePool + Kafka (internal + NodePort listeners)
k8s/akhq/akhq.yaml           AKHQ Deployment + internal Service
k8s/oracle/                  Kustomize: namespace, PVC, services, StatefulSet, setup script
scripts/up.sh | down.sh      lifecycle scripts (settings in scripts/common.sh)
```

## Notes

- With podman ≥ 6, `kind get clusters` fails because of a Go template error. The scripts work around this by checking for the node container directly.
- Rootless podman needs cgroup v2 delegation for Kind; see the [Kind rootless docs](https://kind.sigs.k8s.io/docs/user/rootless/).
