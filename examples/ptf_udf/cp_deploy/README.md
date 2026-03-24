# Confluent Platform SQL Deployment via Flink SQL Client ─ User Event Enricher PTF UDF

> This example deploys the same **User Event Enricher** PTF UDF as the [Java job JAR example](../cp_java/README.md), but instead of compiling a Flink job, it submits SQL statements through the **Flink SQL Client** running directly on the JobManager pod.

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
+ [**5.0 Project structure**](#50-project-structure)
+ [**6.0 Resources**](#60-resources)
<!-- tocstop -->

## **1.0 Overview**

### **1.1 How this differs from the other deployment paths**

| Aspect | CP Java Job JAR | CC Terraform | **CP SQL via Flink SQL Client** (this example) |
|---|---|---|---|
| Where it runs | Confluent Platform (Minikube) | Confluent Cloud | Confluent Platform (Minikube) |
| How SQL is submitted | Compiled into a Java `main()` method | `confluent_flink_statement` Terraform resources | `sql-client.sh -f` on the JobManager pod |
| UDF JAR delivery | Bundled in the fat JAR | `confluent_flink_artifact` (uploaded to CC) | `kubectl exec` to Flink pods |
| Entry point | `ptf.FlinkJob` class | Terraform `apply` | `make deploy-cp-ptf-udf` |
| Requires code compilation | Yes (Java + Gradle) | Yes (Java + Gradle for UDF JAR) | Yes (Java + Gradle for UDF JAR) |
| Statement lifecycle | Managed by Flink runtime | Managed by Terraform state | Managed by Flink session cluster |

---

## **2.0 How it works**

### **2.1 JAR delivery**

On Confluent Cloud, UDF JARs are uploaded as **Flink artifacts** (`confluent-artifact://`). On Confluent Platform, there is no artifact store ─ the JAR must be physically present on the Flink pods.

The deploy script copies the fat JAR (built from [examples/ptf_udf/java/](../java/)) to `/opt/flink/usrlib/user-event-enricher.jar` on every JobManager and TaskManager pod using `kubectl exec`. The `CREATE FUNCTION ... USING JAR` statement then references this pod-local path.

### **2.2 Kafka connector**

The CP Flink base image does not include the Kafka SQL connector. The FlinkDeployment uses two **init containers** to assemble `/opt/flink/lib/` at pod startup:

1. **copy-stock-lib** ─ copies the stock Flink lib JARs from the image into a shared `emptyDir` volume
2. **fetch-kafka-connector** ─ downloads `flink-sql-connector-kafka` from Maven Central into the same volume

The main Flink container then mounts this volume at `/opt/flink/lib/`, so the Kafka connector is on the classpath when the JVM starts.

### **2.3 Statement flow**

The script pre-creates Kafka topics, then executes all SQL in a single `sql-client.sh -f` session on the JobManager pod:

```
┌──────────────────────────────────────────────────────────────────────┐
│  Pre-step: kafka-topics --create user_events, enriched_events       │
│                                                                      │
│  Step 1:  DROP TABLE IF EXISTS user_events              → OK        │
│  Step 2:  CREATE TABLE user_events (... WITH kafka ...) → OK        │
│  Step 3:  INSERT INTO user_events VALUES (sample data)  → submitted │
│  Step 4:  DROP TABLE IF EXISTS enriched_events          → OK        │
│  Step 5:  CREATE TABLE enriched_events (... WITH kafka) → OK        │
│  Step 6:  CREATE FUNCTION user_event_enricher           → OK        │
│           USING JAR '/opt/flink/usrlib/...'                         │
│  Step 7:  INSERT INTO enriched_events                   → submitted │
│           SELECT ... FROM TABLE(user_event_enricher())              │
└──────────────────────────────────────────────────────────────────────┘
```

Step 7 is a **long-running streaming job**. It runs continuously, reading from `user_events` and writing enriched output to `enriched_events`.

---

## **3.0 Prerequisites**

- macOS with Homebrew and Docker Desktop running
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
make deploy-cp-ptf-udf
```

Behind the scenes this runs:

| Step | What it does |
|---|---|
| 1 | `./gradlew clean shadowJar` ─ builds the UDF fat JAR from `examples/ptf_udf/java/` |
| 2 | `kubectl exec` ─ copies the JAR to all JobManager and TaskManager pods |
| 3 | `kafka-topics --create` ─ pre-creates Kafka topics (`user_events`, `enriched_events`) |
| 4 | `sql-client.sh -f` ─ executes all SQL statements in a single session on the JobManager pod |

### **4.2 Monitor**

Open the Flink Dashboard to see the running enrichment job:

```bash
make flink-ui              # opens http://localhost:8081
```

### **4.3 Tear down**

To stop the running enrichment job and drop all tables and functions:

```bash
make teardown-cp-ptf-udf
```

This cancels any running Flink jobs via the Flink REST API, then submits `DROP FUNCTION` and `DROP TABLE` statements.

---

## **5.0 Project structure**

This example relies on the shared Java UDF source in `examples/ptf_udf/java/` and a deploy script:

```
examples/ptf_udf/
├── java/                                # Shared Java UDF source (also used by cc_deploy)
│   ├── app/
│   │   ├── build.gradle.kts             # Gradle build (Flink 2.1.x, Java 17)
│   │   └── src/main/java/ptf/
│   │       └── UserEventEnricher.java   # The ProcessTableFunction implementation
│   ├── gradle/wrapper/
│   │   └── gradle-wrapper.properties
│   ├── gradlew
│   ├── gradlew.bat
│   └── settings.gradle.kts
│
├── cp_deploy/                 # This example
│   └── README.md                        # You are here
│
scripts/
└── deploy-cp-ptf-udf.sh      # Shell script that drives the deployment
```

---

## **6.0 Resources**

- [Flink SQL Client](https://nightlies.apache.org/flink/flink-docs-stable/docs/dev/table/sqlclient/)
- [Flink Kafka Connector](https://nightlies.apache.org/flink/flink-docs-stable/docs/connectors/table/kafka/)
- [Create a User-Defined Function with Confluent Cloud for Apache Flink](https://docs.confluent.io/cloud/current/flink/how-to-guides/create-udf.html)
