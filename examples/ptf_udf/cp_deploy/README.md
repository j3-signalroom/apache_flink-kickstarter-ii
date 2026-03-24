# Confluent Platform SQL Statement Submission via CMF REST API ─ User Event Enricher PTF UDF

> This example deploys the same **User Event Enricher** PTF UDF as the [Java job JAR example](../cp_java/README.md), but instead of compiling a Flink job, it submits individual SQL statements through the **Confluent Manager for Apache Flink (CMF)** REST API.

**Table of Contents**
<!-- toc -->
+ [**1.0 Overview**](#10-overview)
    + [**1.1 What is CMF?**](#11-what-is-cmf)
    + [**1.2 How this differs from the other deployment paths**](#12-how-this-differs-from-the-other-deployment-paths)
+ [**2.0 How it works**](#20-how-it-works)
    + [**2.1 JAR delivery**](#21-jar-delivery)
    + [**2.2 Statement flow**](#22-statement-flow)
+ [**3.0 Prerequisites**](#30-prerequisites)
+ [**4.0 How to run**](#40-how-to-run)
    + [**4.1 Deploy**](#41-deploy)
    + [**4.2 Monitor**](#42-monitor)
    + [**4.3 Tear down**](#43-tear-down)
+ [**5.0 Project structure**](#50-project-structure)
+ [**6.0 Resources**](#60-resources)
<!-- tocstop -->

## **1.0 Overview**

### **1.1 What is CMF?**

**Confluent Manager for Apache Flink (CMF)** is a management layer that runs alongside the Flink Kubernetes Operator on Confluent Platform. It exposes a REST API for managing Flink environments, submitting SQL statements, and monitoring statement lifecycle ─ all without requiring direct access to the Flink SQL Client or JobManager pod.

On Confluent Cloud, you interact with Flink through the Console, CLI, or Terraform (`confluent_flink_statement`). CMF brings the same statement-management model to **self-managed** Confluent Platform deployments.

### **1.2 How this differs from the other deployment paths**

| Aspect | CP Java Job JAR | CC Terraform | **CP SQL via CMF** (this example) |
|---|---|---|---|
| Where it runs | Confluent Platform (Minikube) | Confluent Cloud | Confluent Platform (Minikube) |
| How SQL is submitted | Compiled into a Java `main()` method | `confluent_flink_statement` Terraform resources | `confluent flink statement` CLI commands |
| UDF JAR delivery | Bundled in the fat JAR | `confluent_flink_artifact` (uploaded to CC) | `kubectl cp` to Flink pods |
| Entry point | `ptf.FlinkJob` class | Terraform `apply` | `make deploy-cp-ptf-udf` |
| Requires code compilation | Yes (Java + Gradle) | Yes (Java + Gradle for UDF JAR) | Yes (Java + Gradle for UDF JAR) |
| Statement lifecycle | Managed by Flink runtime | Managed by Terraform state | Managed by CMF (create / list / delete) |

---

## **2.0 How it works**

### **2.1 JAR delivery**

On Confluent Cloud, UDF JARs are uploaded as **Flink artifacts** (`confluent-artifact://`). On Confluent Platform, there is no artifact store ─ the JAR must be physically present on the Flink pods.

The deploy script copies the fat JAR (built from [examples/ptf_udf/java/](../java/)) to `/opt/flink/usrlib/user-event-enricher.jar` on every JobManager and TaskManager pod using `kubectl cp`. The `CREATE FUNCTION ... USING JAR` statement then references this pod-local path.

### **2.2 Statement flow**

The script submits seven SQL statements sequentially, waiting for each to reach its expected phase before proceeding:

```
┌──────────────────────────────────────────────────────────────────────┐
│  Step 1:  DROP TABLE IF EXISTS user_events              → COMPLETED │
│  Step 2:  CREATE TABLE user_events (... WITH kafka ...) → COMPLETED │
│  Step 3:  INSERT INTO user_events VALUES (sample data)  → COMPLETED │
│  Step 4:  DROP TABLE IF EXISTS enriched_events          → COMPLETED │
│  Step 5:  CREATE TABLE enriched_events (... WITH kafka) → COMPLETED │
│  Step 6:  CREATE FUNCTION user_event_enricher           → COMPLETED │
│           USING JAR '/opt/flink/usrlib/...'                         │
│  Step 7:  INSERT INTO enriched_events                   → RUNNING   │
│           SELECT ... FROM TABLE(user_event_enricher())              │
└──────────────────────────────────────────────────────────────────────┘
```

Step 7 is a **long-running streaming job**. It runs continuously, reading from `user_events` and writing enriched output to `enriched_events`. The script exits once Flink confirms the job is `RUNNING`.

Each statement is submitted using the Confluent CLI:

```bash
confluent flink statement create --sql "CREATE TABLE ..." \
    --environment dev-local \
    --url http://localhost:18080
```

The script polls `confluent flink statement describe <name>` until the statement reaches its expected phase (`COMPLETED` or `RUNNING`) or `FAILED`.

---

## **3.0 Prerequisites**

- macOS with Homebrew and Docker Desktop running
- Java 17+
- Confluent Platform and Flink stack already deployed:

```bash
make install-prereqs       # installs tooling (docker, kubectl, minikube, helm, gradle, etc.)
make cp-up                 # Minikube → CFK Operator → Kafka + SR + Connect + C3 + Kafka UI
make cp-watch              # watch pods come up (Ctrl+C when all Running)
make flink-up              # cert-manager → Flink Operator → CMF → Flink session cluster
make flink-status          # verify Flink pods are Running
make cmf-status            # verify CMF pod is Running and 'dev-local' environment exists
```

---

## **4.0 How to run**

All commands are run from the **project root** (where the `Makefile` lives).

### **4.1 Deploy**

A single target builds the UDF JAR, copies it to the Flink pods, and submits all SQL statements via CMF:

```bash
make deploy-cp-ptf-udf
```

Behind the scenes this runs:

| Step | What it does |
|---|---|
| 1 | `./gradlew clean shadowJar` ─ builds the UDF fat JAR from `examples/ptf_udf/java/` |
| 2 | `kubectl cp` ─ copies the JAR to all JobManager and TaskManager pods |
| 3 | Port-forwards to CMF service (`svc/cmf-service`) |
| 4 | Submits 7 SQL statements sequentially, waiting for each to complete |

### **4.2 Monitor**

Open the Flink Dashboard to see the running enrichment job:

```bash
make flink-ui              # opens http://localhost:8081
```

Check CMF statement status:

```bash
make cmf-open              # opens CMF REST API at http://localhost:8080
```

Then browse to `http://localhost:8080/cmf/api/v1/environments/dev-local/statements` to see all submitted statements and their phases.

### **4.3 Tear down**

To stop the running enrichment job and drop all tables and functions:

```bash
make teardown-cp-ptf-udf
```

This cancels any `RUNNING` statements, then submits `DROP FUNCTION` and `DROP TABLE` statements via CMF.

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
└── deploy-cp-ptf-udf.sh      # Shell script that drives the CMF deployment
```

---

## **6.0 Resources**

- [Submit a Flink SQL Statement with Confluent Manager for Apache Flink](https://docs.confluent.io/platform/current/flink/get-started/get-started-statement.html)
- [CMF REST API Reference](https://docs.confluent.io/platform/current/flink/cmf/cmf-rest-api.html)
- [Create a User-Defined Function with Confluent Cloud for Apache Flink](https://docs.confluent.io/cloud/current/flink/how-to-guides/create-udf.html)
