# Confluent Platform SQL Deployment via Flink SQL Client ─ Session Timeout Detector PTF UDF

> This example deploys the **Session Timeout Detector** PTF UDF (source in [examples/ptf_udf_timer_driven/java/](../java/)) by submitting SQL statements through the **Flink SQL Client** running directly on the JobManager pod.

**Table of Contents**
<!-- toc -->
+ [**1.0 Overview**](#10-overview)
    + [**1.1 How this differs from the other deployment paths**](#11-how-this-differs-from-the-other-deployment-paths)
+ [**2.0 How it works**](#20-how-it-works)
    + [**2.1 JAR delivery**](#21-jar-delivery)
    + [**2.2 Kafka connector**](#22-kafka-connector)
    + [**2.3 Statement flow**](#23-statement-flow)
+ [**3.0 Prerequisites**](#30-prerequisites)
+ [**4.0 How to run**](#40-how-to-run)
    + [**4.1 Deploy**](#41-deploy)
    + [**4.2 Monitor**](#42-monitor)
    + [**4.3 Tear down**](#43-tear-down)
+ [**5.0 Resources**](#50-resources)
<!-- tocstop -->

## **1.0 Overview**

### **1.1 How this differs from the other deployment paths**

| Aspect | **Confluent Platform SQL Client** (this example) | Confluent Cloud Terraform |
|---|---|---|
| Where it runs | Confluent Platform + Minikube | Confluent Cloud |
| How SQL is submitted | `sql-client.sh -f` on the JobManager pod | `confluent_flink_statement` Terraform resources |
| UDF JAR delivery | `kubectl exec` to Flink pods | `confluent_flink_artifact` (uploaded to CC) |
| Entry point | `make deploy-cp-ptf-udf-timer-driven` | `make deploy-cc-ptf-udf-timer-driven` |
| Requires code compilation | Yes (Java + Gradle for UDF JAR) | Yes (Java + Gradle for UDF JAR) |
| Statement lifecycle | Managed by Flink session cluster | Managed by Terraform state |
| Same codebase for both? | Yes (**same Java UDF code**, different Terraform vs SQL Client for deployment) | Yes (**same Java UDF code**, different Terraform vs SQL Client for deployment) |

---

## **2.0 How it works**

### **2.1 JAR delivery**

On Confluent Platform there is no artifact store ─ the JAR must be physically present on the Flink pods.

The deploy script copies the fat JAR (built from [examples/ptf_udf_timer_driven/java/](../java/)) to `/opt/flink/usrlib/session-timeout-detector.jar` on every JobManager and TaskManager pod using `kubectl exec`. The `CREATE FUNCTION ... USING JAR` statement then references this pod-local path.

### **2.2 Kafka connector**

The CP Flink base image does not include the Kafka SQL connector. The FlinkDeployment uses two **init containers** to assemble `/opt/flink/lib/` at pod startup:

1. **copy-stock-lib** ─ copies the stock Flink lib JARs from the image into a shared `emptyDir` volume
2. **fetch-kafka-connector** ─ downloads `flink-sql-connector-kafka` from Maven Central into the same volume

The main Flink container then mounts this volume at `/opt/flink/lib/`, so the Kafka connector is on the classpath when the JVM starts.

### **2.3 Statement flow**

The script pre-creates Kafka topics, then executes all SQL in a single `sql-client.sh -f` session on the JobManager pod:

```
┌──────────────────────────────────────────────────────────────────────┐
│  Pre-step: kafka-topics --create user_activity, timeout_events       │
│                                                                      │
│  Step 1:  DROP TABLE IF EXISTS user_activity            → OK         │
│  Step 2:  CREATE TABLE user_activity (... WITH kafka)   → OK         │
│           (includes event_time with watermark)                       │
│  Step 3:  INSERT INTO user_activity VALUES (sample data) → submitted │
│  Step 4:  DROP TABLE IF EXISTS timeout_events           → OK         │
│  Step 5:  CREATE TABLE timeout_events (... WITH kafka)  → OK         │
│  Step 6:  CREATE FUNCTION session_timeout_detector      → OK         │
│           USING JAR '/opt/flink/usrlib/...'                          │
│  Step 7:  INSERT INTO timeout_events                    → submitted  │
│           SELECT ... FROM TABLE(session_timeout_detector())          │
└──────────────────────────────────────────────────────────────────────┘
```

Step 7 is a **long-running streaming job**. It runs continuously, reading from `user_activity` and writing timeout detection output to `timeout_events`.

---

## **3.0 Prerequisites**

- macOS with Homebrew or Linux with apt-get, and Docker Desktop running
- Java 17+
- Confluent Platform and Flink stack already deployed:

```bash
make install-prereqs       # installs tooling (docker, kubectl, minikube, helm, gradle)
make cp-up                 # Minikube → CFK Operator → Kafka + SR + Connect + C3 + Kafka UI
make cp-watch              # watch pods come up (Ctrl+C when all Running)
make flink-up              # cert-manager → Flink Operator → CMF → Flink session cluster
make flink-status          # verify Flink pods are Running
```

---

## **4.0 How to run**

All commands are run from the **project root** (where the `Makefile` lives).

### **4.1 Deploy**

A single target builds the UDF JAR, copies it to the Flink pods, and executes all SQL:

```bash
make deploy-cp-ptf-udf-timer-driven
```

Behind the scenes this runs:

| Step | What it does |
|---|---|
| 1 | `./gradlew clean shadowJar` ─ builds the UDF fat JAR from `examples/ptf_udf_timer_driven/java/` |
| 2 | `kubectl exec` ─ copies the JAR to all JobManager and TaskManager pods |
| 3 | `kafka-topics --create` ─ pre-creates Kafka topics (`user_activity`, `timeout_events`) |
| 4 | `sql-client.sh -f` ─ executes all SQL statements in a single session on the JobManager pod |

### **4.2 Monitor**

Open the Flink Dashboard to see the running timeout detection job:

```bash
make flink-ui              # opens http://localhost:8081
```

### **4.3 Tear down**

To stop the running timeout detection job and drop all tables and functions:

```bash
make teardown-cp-ptf-udf-timer-driven
```

This cancels any running Flink jobs via the Flink REST API, then submits `DROP FUNCTION` and `DROP TABLE` statements.

---

## **5.0 Resources**

- [Flink SQL Client](https://nightlies.apache.org/flink/flink-docs-stable/docs/dev/table/sqlclient/)
- [Flink Kafka Connector](https://nightlies.apache.org/flink/flink-docs-stable/docs/connectors/table/kafka/)
- [Process Table Functions (PTFs)](https://nightlies.apache.org/flink/flink-docs-master/docs/dev/table/functions/ptfs/)
- [Create a User-Defined Function (Confluent Cloud)](https://docs.confluent.io/cloud/current/flink/how-to-guides/create-udf.html)
