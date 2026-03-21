# Apache Flink Kickstarter II

A hands-on project for running **Apache Flink** on **Confluent Platform** locally using Minikube. Includes a working example of Flink's **Process Table Function (PTF)** API with stateful per-key enrichment.

---

## Quickstart

### Prerequisites

macOS with Homebrew and Docker Desktop running.

```bash
make install-prereqs   # installs docker, kubectl, minikube, helm, envsubst
```

### 1. Deploy Confluent Platform

```bash
make cp-up             # Minikube → CFK Operator → Kafka (KRaft) + SR + Connect + ksqlDB + C3 + Kafka UI
make cp-watch          # watch pods come up (Ctrl+C when all Running)
```

### 2. Deploy Apache Flink + CMF

```bash
make flink-up          # cert-manager → Flink Operator → CMF → Flink session cluster
make flink-status      # verify Flink pods are Running
```

### 3. Run the PTF UDF Example

The example job (`cp_java_examples/ptf_udf/`) demonstrates a stateful **ProcessTableFunction** that reads user events from Kafka, enriches each event with a per-user session ID and running event count, and writes the results back to Kafka.

**Build the fat JAR:**

```bash
make build-cp-java-ptf-udf
```

**Create the Kafka topics:**

```bash
kubectl exec -n confluent kafka-0 -- kafka-topics --bootstrap-server localhost:9092 \
    --create --if-not-exists --topic user-events --partitions 1 --replication-factor 1

kubectl exec -n confluent kafka-0 -- kafka-topics --bootstrap-server localhost:9092 \
    --create --if-not-exists --topic enriched-events --partitions 1 --replication-factor 1
```

**Upload and submit the job via the Flink UI:**

```bash
make flink-ui          # opens http://localhost:8081
```

In the Flink UI: **Submit New Job** → upload `cp_java_examples/ptf_udf/target/cp-apache_flink-ptf-udf-example-1.0.0-SNAPSHOT.jar` → set Entry Class to `ptf.FlinkJob` → **Submit**.

**Produce sample records:**

```bash
printf '%s\n' \
    '{"user_id":"alice","event_type":"login","payload":"web"}' \
    '{"user_id":"bob","event_type":"click","payload":"button-checkout"}' \
    '{"user_id":"alice","event_type":"purchase","payload":"order-1234"}' \
    '{"user_id":"charlie","event_type":"login","payload":"mobile"}' \
    '{"user_id":"bob","event_type":"logout","payload":"session-end"}' \
    '{"user_id":"alice","event_type":"click","payload":"button-settings"}' \
| kubectl exec -i -n confluent kafka-0 -- \
    kafka-console-producer --bootstrap-server localhost:9092 --topic user-events
```

**Consume enriched output:**

```bash
kubectl exec -n confluent kafka-0 -- kafka-console-consumer \
    --bootstrap-server localhost:9092 --topic enriched-events --from-beginning
```

You should see enriched JSON records with `session_id`, `event_count`, and `last_event` fields added by the PTF.

### 4. Access the UIs

```bash
make c3-open           # Control Center   → http://localhost:9021
make flink-ui          # Flink Dashboard  → http://localhost:8081
make kafka-ui-open     # Kafka UI         → http://localhost:8080
make cmf-open          # CMF REST API     → http://localhost:8080
```

### 5. Teardown

```bash
make confluent-teardown   # removes everything and stops Minikube
```

---

## How the PTF UDF Example Works

| Component | Description |
|-----------|-------------|
| `FlinkJob.java` | Entry point — creates Kafka source/sink tables via Flink SQL and invokes the PTF |
| `UserEventEnricher.java` | A `ProcessTableFunction` that maintains per-user state (`session_id`, `event_count`, `last_event`) |

**Data flow:**

```
user-events topic → [Kafka Source] → UserEventEnricher PTF → [Kafka Sink] → enriched-events topic
```

The PTF partitions by `user_id` so each user gets independent state. A new session starts on every `"login"` event, resetting the event counter.

**Input schema** (`user-events`):
```json
{"user_id": "alice", "event_type": "login", "payload": "web"}
```

**Output schema** (`enriched-events`):
```json
{"user_id": "alice", "event_type": "login", "payload": "web", "session_id": 1, "event_count": 1, "last_event": "login"}
```

---

## Documentation

- [Minikube Deployment Guide](docs/minikube-deployment.md) — full reference for all Make targets, configuration variables, and architecture diagrams
- [Manual Deployment](docs/manual_deployment.md) — step-by-step instructions without the Makefile

## Resources

- [Confluent Platform for Apache Flink](https://docs.confluent.io/platform/current/flink/get-started/overview.html)
- [Confluent for Kubernetes](https://docs.confluent.io/operator/current/co-manage-overview.html)
- [Flink Process Table Functions](https://nightlies.apache.org/flink/flink-docs-release-2.1/docs/dev/table/functions/processtablefunctions/)
