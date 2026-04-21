# ![apache-flink-logo](docs/images/apache_flink.png) Apache Flink Kickstarter II **[UNDER CONSTRUCTION]**

> **_On GitHub, Watch → Custom → Releases is the most useful setting if you want to stay updated on when something important is released for this project._**

**Apache Flink Kickstarter II** is the 2026 evolution of my original Kickstarter project ─ rebuilt to showcase the cutting edge of the [Confluent distribution of Open Software Source (OSS)] **Apache Flink 2.1.x**.

Designed as a hands-on, production-minded accelerator, it brings Flink to life _locally_ on **Confluent Platform on Minikube**, while drawing direct comparisons to **Confluent Cloud for Apache Flink** ─ so you can clearly see what’s possible across environments.

Every **example** is delivered end-to-end ─ from schema design to fully operational streaming pipelines ─ with implementations in **both Java and Python (when possible)** where it matters, bridging real-world developer workflows with modern streaming architecture.

---

**Table of Contents**
<!-- toc -->
+ [**1.0 Prerequisites**](#10-prerequisites)
    - [**1.1 Confluent Platform on Minikube — Production-Like Streaming, Running Locally**](#11-confluent-platform-on-minikube--production-like-streaming-running-locally)
    - [**1.2 Confluent Cloud**](#12-confluent-cloud)
+ [**2.0 The Examples**](#20-the-examples)
    - [**2.1 Apache Flink User-Defined Functions (UDF)**](#21-apache-flink-user-defined-functions-udf)
        + [**2.1.1 Process Table Functions (PTF)**](#211-process-table-functions-ptf)
            - [**2.1.1.1 Limitation(s)**](#2111-limitations)
        + [**2.1.2 Scalars**](#212-scalars)
+ [**3.0 Debugging the Examples**](#30-debugging-the-examples)
    - [**3.1 Apache Flink UDF Debugging with Java Debug Wire Protocol (JDWP)**](#31-apache-flink-udf-debugging-with-java-debug-wire-protocol-jdwp)
        + [**3.1.1 Process Table Functions (PTF)**](#311-process-table-functions-ptf)
            - [**3.1.1.1 Debugging the `row-driven` PTF using set semantics (`UserEventEnricher`)**](#3111-debugging-the-row-driven-ptf-using-set-semantics-usereventenricher)
            - [**3.1.1.2 Debugging the `row-driven` PTF using row semantics (`OrderLineExpander`)**](#3112-debugging-the-row-driven-ptf-using-row-semantics-orderlineexpander)
            - [**3.1.1.3 Debugging the `timer-driven` PTFs (`SessionTimeoutDetector`, `AbandonedCartDetector`, `PerEventFollowUp`, and `SlaMonitor`)**](#3113-debugging-the-timer-driven-ptfs-sessiontimeoutdetector-abandonedcartdetector-pereventfollowup-and-slamonitor)
        + [**3.1.2 Scalars**](#312-scalars)
            - [**3.1.2.1 Debugging the Celsius to Fahrenheit Scalar UDF (`CelsiusToFahrenheit`)**](#3121-debugging-the-celsius-to-fahrenheit-scalar-udf-celsiustofahrenheit)
+ [**4.0 Resources**](#40-resources)
    - [**4.1 Confluent for Kubernetes (CfK)**](#41-confluent-for-kubernetes-cfk)
    - [**4.2 Confluent Platform for Apache Flink**](#42-confluent-platform-for-apache-flink)
    - [**4.3 Confluent Cloud for Apache Flink (CCAF)**](#43-confluent-cloud-for-apache-flink-ccaf)
<!-- tocstop -->

---

## **1.0 Prerequisites**

First, clone the repo to your local machine using the [GitHub CLI](https://cli.github.com/):

```bash
gh repo clone j3-signalroom/apache_flink-kickstarter-ii
```

Change to the repo directory:

```bash
cd /path/to/apache_flink-kickstarter-ii
```

Then decide where you want to run the examples:

### **1.1 Confluent Platform on Minikube — Production-Like Streaming, Running Locally**
To **_run_**, **_test_**, and **_debug_** Apache Flink like a production engineer, this project provides a full Confluent Platform stack running locally on [Minikube](https://minikube.sigs.k8s.io/docs/) — no cloud required.

You get a production-like environment on your machine, with all the components you’d expect in a real deployment:

- **Confluent Platform** (KRaft mode) via Confluent for Kubernetes (CFK)
- **Apache Flink 2.1.1** via the Confluent Flink Kubernetes Operator 1.130
- **Confluent Manager for Apache Flink (CMF) 2.1** for Flink environment management

To run this project, you’ll need **macOS (with Homebrew)** or **Linux (with apt-get)**.  The full stack — **Minikube + Confluent Platform + Flink + CMF** — is resource-intensive and designed to mirror a production environment. Therefore, the following defaults are recommended:

| Resource | Default |
| -------- | ------- |
| CPUs     | 6       |
| Memory   | 20 GB   |
| Disk     | 50 GB   |

> These settings ensure stable performance across all components. You can tune them as needed, but lower resource levels may cause pod restarts or degraded performance.

👉 If your machine meets all the requirements, click [**here**](docs/running-make.md).  Otherwise, click [**here**](docs/remote-server-ssh-tunneling.md) to set up a *Remote Server Setup (SSH Tunneling)* on a provider like [Vultr VPS](https://www.vultr.com/).

🧠 **_Build locally. Debug with confidence. Deploy to production-ready environments._**

---

### **1.2 Confluent Cloud**

In addition to running the examples **locally**, you can also run them in Confluent Cloud.  The examples are designed to mirror the local Confluent Platform setup as closely as possible, so you can easily compare and contrast the two environments.  Or, better yet, run the same example in both environments to confirm that they behave the same way.

Before you begin, ensure you have access to the following cloud accounts:

* **[Confluent Cloud Account](https://confluent.cloud/)** — for Kafka, Schema Registry, and Flink resources
* **[Terraform Cloud Account](https://app.terraform.io/)** — for automated infrastructure provisioning

Make sure the following tools are installed on your local machine:

* **[Java JDK 21](https://www.oracle.com/java/technologies/javase/jdk21-archive-downloads.html)** — for building Flink UDFs
* **[Gradle 9.4.1 or higher](https://gradle.org/install/)** — for building Flink UDFs
* **[Terraform CLI version 1.13.0 or higher](https://developer.hashicorp.com/terraform/install)** — for deploying infrastructure to Confluent Cloud

---

## **2.0 The Examples**

Once you’ve set up [**Confluent Platform on Minikube**](#11-confluent-platform-on-minikube--production-like-streaming-running-locally) or have your [**Confluent Cloud**](#12-confluent-cloud) account with the prerequisites in place, you’re ready to try the examples:

### **2.1 Apache Flink User-Defined Functions (UDF)**

#### **2.1.1 Process Table Functions (PTF)**

<details>
<summary><strong><em>What are PTFs?</em></strong></summary>

PTFs are a special type of Apache Flink UDF that offers stateful, timer-aware processing capabilities directly within Flink SQL. PTFs can be either **`row-driven`** (invoked for each input row) or **`timer-driven`** (triggered based on timers you set in your code).

</details>

<details>
<summary><strong><em>Why use PTFs?</em></strong></summary>

PTF UDFs are ideal when you need memory across rows, respond to time passing — not just on arriving data, or you want to implement complex event processing (CEP) patterns that are difficult to express in pure Flink SQL.

</details>

<details>
<summary><strong><em>When do you use PTFs?</em></strong></summary>

PTFs are used when your use case requires state and/or timers that go beyond what standard Flink SQL can handle. For example: **Stateful Enrichment with or without External Lookups**, **Per-Row Stateful Transformation**, **Complex Conditional Routing and/or Filtering**, **Session timeout**, **Abandoned cart**, **Device heartbeat monitoring**, **Per-event follow-up**, **SLA monitoring**, **Delayed side-effects**, and more.

</details>

<details>
<summary><strong><em>Where do you use PTFs?</em></strong></summary>

You write PTF UDFs as Java classes, deploy them as JAR files, and run them within your Flink SQL queries.

</details>

<details open>
<summary><strong><em>How are examples of PTFs put into practice?</em></strong></summary>

| Type | Purpose | Confluent Platform on Minikube | Confluent Cloud |
| --- | --- | --- | --- |
| [PTF UDF-type (`row-driven`)](examples/ptf_udf_row_driven/java/README.md) | Walks through both **local** and cloud environments *building*, *deploying*, and *testing* two **`row-driven`** **PTF UDFs** (no timers) bundled in one JAR that illustrate both `ArgumentTrait` modes: **User Event Enricher** (`SET_SEMANTIC_TABLE` — enriches Kafka user events with per-user session tracking using keyed state) and **Order Line Expander** (`ROW_SEMANTIC_TABLE` — stateless one-to-many expansion of an order row into individual line items). | <p style="text-align: center;">[`CP Deploy`](examples/ptf_udf_row_driven/cp_deploy/README.md)</p> | <p style="text-align: center;">[`CC Deploy`](examples/ptf_udf_row_driven/cc_deploy/README.md)</p> |
| [PTF UDF-type (`timer-driven`)](examples/ptf_udf_timer_driven/java/README.md) | Walks through both **local** and cloud environments *building*, *deploying*, and *testing* four **`timer-driven`** **PTF UDFs** bundled in one JAR: **Session Timeout Detector** (named timers using the inactivity pattern), **Abandoned Cart Detector** (named timers using the inactivity pattern for e-commerce), **Per-Event Follow-Up** (unnamed timers using the scheduling pattern), and **SLA Monitor** (unnamed timers using the scheduling pattern). | <p style="text-align: center;">[`CP Deploy`](examples/ptf_udf_timer_driven/cp_deploy/README.md)</p> | <p style="text-align: center;">[`CC Deploy`](examples/ptf_udf_timer_driven/cc_deploy/README.md)</p> |

</details>

[⏳ **PTF Rules of Thumb: The Hourglass Pattern**](docs/flink-sql-lateral-view-vs-ptf.md)

##### **2.1.1.1 Limitation(s)**

- [Why `@StateHint` POJO with `Map` or `List` Are Sensitive to "Extremely Large State"](docs/ccaf-map-list-ptf-udf-limitation-explanation.md)

#### **2.1.2 Scalars**

<details>
<summary><strong><em>What are Scalars?</em></strong></summary>

First, what is a **scalar** value?  A scalar is a single, atomic value — one number, one string, one boolean, or one timestamp — as opposed to a collection or composite structure.  The term comes from mathematics (a scalar is a magnitude without direction, in contrast to a vector, which has both magnitude and direction), and it carries into computing with the same core meaning: one value, not many.

A **Scalar UDF** is a custom function that takes zero or more input arguments and returns a single scalar value per row. It's the simplest and most common type of UDF in SQL engines.

> **Note**: In Flink, there is a subtle nuance. A scalar can return a `ROW< ... >` or an `ARRAY< ... >` and is still classified as "scalar" in the *function classification sense*, even though the value itself is composite. The classification is about **"one output value per input row," not about whether that value is primitive**. This trips people up occasionally — a UDF that returns `ROW<masked_email STRING, hash_prefix STRING>` is still a Scalar UDF.

**Core Characteristics:**

- **Row-by-row evaluation**: called once per input row, produces one output value per call
- **Stateless by default**: no access to *keyed state*, *timers*, or *watermarks* (unlike PTFs or aggregate functions)
- **Deterministic or non-deterministic**: you can declare `isDeterministic()` — affects query optimization and plan caching
- **Type-inferred**: return type can be auto-inferred or explicitly declared via `@DataTypeHint` / `getTypeInference()`

</details>

<details>
<summary><strong><em>Why use Scalars?</em></strong></summary>

Scalar functions earn their keep when you need per-row transformation logic that’s either too complex, too reusable, or too encapsulated for inline SQL expressions.  Here is a list of reasons to use scalars:

- **Encapsulate logic that SQL expresses poorly**
- **Reusability and DRY (Don't Repeat Yourself)**
- **Consistency and governance**
- **Access to the host language ecosystem**
- **Hiding complexity from SQL creaters**

</details>

<details>
<summary><strong><em>When do you use Scalars?</em></strong></summary>

Scalars are used when your use case requires a transformation that is awkward or impossible to do in pure SQL. Moreover, they are used when you only need to supply zero or more input arguments and return a single value per row.

</details>

<details>
<summary><strong><em>Where do you use Scalars?</em></strong></summary>

You write Scalar UDFs as Java classes, deploy them as JAR files, and run them within your Flink SQL queries.

</details>

<details open>
<summary><strong><em>How are examples of Scalars put into practice?</em></strong></summary>

| Type | Purpose | Confluent Platform on Minikube | Confluent Cloud |
| --- | --- | --- | --- |
| [Scalar UDF-type](examples/scalar_udf/java/README.md) | Walks through both **local** and cloud environments *building*, *deploying*, and *testing* two **Scalar UDFs** bundled in a single JAR that illustrate the simplest and oldest category of Flink user-defined function — a pure, row-at-a-time function callable from SQL. The first, **`CelsiusToFahrenheit`**, converts a Celsius temperature to its Fahrenheit equivalent, and the second, **`FahrenheitToCelsius`**, converts a Fahrenheit temperature to its Celsius equivalent. | <p style="text-align: center;">[`CP Deploy`](examples/scalar_udf/cp_deploy/README.md)</p> | <p style="text-align: center;">[`CC Deploy`](examples/scalar_udf/cc_deploy/README.md)</p> |

</details>

---

## **3.0 Debugging the Examples**

### **3.1 Apache Flink UDF Debugging with Java Debug Wire Protocol (JDWP)**

You can attach your IDE's debugger (VS Code or IntelliJ IDEA) to a running Flink TaskManager and _hit breakpoints inside your UDF code_ — even though it's executing on a remote Java Virtual Machine (JVM) inside Kubernetes. The [`FlinkDeployment` Custom Resource (CR)](k8s/base/flink-basic-deployment.yaml) already has **Java Debug Wire Protocol (JDWP)** enabled, and debug configurations are pre-wired for both [VS Code](.vscode/launch.json) and [IntelliJ IDEA](.idea/runConfigurations/).

**Prerequisites:** The Confluent Platform and Flink stack must be running (`make cp-up && make flink-up`), and your UDF must be deployed.

#### **3.1.1 Process Table Functions (PTF)**

##### **3.1.1.1 Debugging the `row-driven` PTF using set semantics (`UserEventEnricher`)**

> For the full deep-dive, see [Remote Debugging `row-driven` Flink PTF UDFs](examples/ptf_udf_row_driven/java/remote-debugging-flink-ptf_udf_row_driven.md). The same guide also covers debugging `OrderLineExpander` (§1.3).

Deploy first: `make deploy-cp-ptf-udf-row-driven`, and then:

<details>
<summary>1. Set a breakpoint</summary>

Open [`UserEventEnricher.java`](examples/ptf_udf_row_driven/java/app/src/main/java/ptf/UserEventEnricher.java) and click in the gutter at the first line of the `eval()` method:

```java
String eventType = input.getFieldAs("event_type");
```

</details>

<details>
<summary>2. Attach the debugger</summary>

Select the **"Attach to Flink TaskManager (Row-Driven)"** configuration and start debugging. The IDE will [automatically port-forward](scripts/port-forward-taskmanager.sh) to the TaskManager pod and attach to the JDWP agent on port `5005`.

- **VS Code:** Open the **Run and Debug** panel (⇧⌘D), select the configuration from the dropdown, and press **F5**
- **IntelliJ IDEA:** Open the **Run/Debug Configurations** dropdown (top-right toolbar), select the configuration, and click **Debug** (⌃D / Shift+F9)

</details>

<details>
<summary>3. Send a test event</summary>

Produce a single JSON message to the `user_events` topic to trigger the breakpoint:

```bash
make produce-user-events-record
```

</details>

<details>
<summary>4. Debug</summary>

Your IDE will pause at your breakpoint. You can inspect `input`, `state`, and local variables, step through the session logic, and watch `state.sessionId` and `state.eventCount` update as you step over lines.

</details>

##### **3.1.1.2 Debugging the `row-driven` PTF using row semantics (`OrderLineExpander`)**

> For the full deep-dive, see [Remote Debugging `row-driven` Flink PTF UDFs](examples/ptf_udf_row_driven/java/remote-debugging-flink-ptf_udf_row_driven.md) (§1.3).
>
> The `OrderLineExpander` ships in the **same uber JAR** as `UserEventEnricher`, so the same `make deploy-cp-ptf-udf-row-driven` command and the same **"Attach to Flink TaskManager (`row-driven`)"** debug configuration are used. The deploy script registers both PTFs as separate Flink SQL functions and starts an `INSERT INTO orders_expanded SELECT ... FROM TABLE(order_line_expander(input => TABLE orders))` pipeline alongside the user-event enrichment job.

Deploy first: `make deploy-cp-ptf-udf-row-driven`, and then:

<details>
<summary>1. Set a breakpoint</summary>

Open [`OrderLineExpander.java`](examples/ptf_udf_row_driven/java/app/src/main/java/ptf/OrderLineExpander.java) and click in the gutter at the first line of the `eval()` method:

```java
String orderId  = input.getFieldAs("order_id");
```

Or, to inspect the per-item emission, set a breakpoint inside the expansion `for` loop on the `collect(Row.of(...))` call.

</details>

<details>
<summary>2. Attach the debugger</summary>

Use the **same** **"Attach to Flink TaskManager (Row-Driven)"** configuration as `UserEventEnricher` — both PTFs run in the same TaskManager pod from the same JAR. The IDE will [automatically port-forward](scripts/port-forward-taskmanager.sh) to the TaskManager pod and attach to the JDWP agent on port `5005`.

- **VS Code:** Open the **Run and Debug** panel (⇧⌘D), select the configuration from the dropdown, and press **F5**
- **IntelliJ IDEA:** Open the **Run/Debug Configurations** dropdown (top-right toolbar), select the configuration, and click **Debug** (⌃D / Shift+F9)

</details>

<details>
<summary>3. Send a test order</summary>

Produce a single JSON order to the `orders` topic to trigger the breakpoint:

```bash
make produce-orders-record
```

The sample record has three items in its comma-separated list, so `eval()` will fire once and the `for` loop inside it will emit three rows.

</details>

<details>
<summary>4. Debug</summary>

Your IDE will pause at your breakpoint. Inspect `input`, the parsed `itemParts` and `quantityParts` arrays, and step through the `for` loop watching `i`, `itemName`, `qty`, and the `collect()` call. Notice that:

- There is **no `state` parameter** — row semantics forbids `@StateHint`, so nothing is preserved between rows.
- There is **no `Context` parameter** — no timers or keyed-state services are accessible.
- A single `eval()` call emits **multiple output rows** via repeated `collect()` calls — this is the canonical one-to-many pattern that distinguishes row-semantic PTFs from scalar UDFs.

> **Row-semantic debugging tip:** Because `OrderLineExpander` is stateless, every input row hits `eval()` independently and the framework is free to distribute rows across virtual processors. If you produce multiple orders in quick succession your breakpoint may fire on any TaskManager slot — and rows from different orders may interleave in arbitrary order. Use the `order_id` field in the watch panel to keep track of which row you're inspecting.

</details>

##### **3.1.1.3 Debugging the `timer-driven` PTFs (`SessionTimeoutDetector`, `AbandonedCartDetector`, `PerEventFollowUp`, and `SlaMonitor`)**

> For the full deep-dive, see [Remote Debugging `timer-driven` Flink PTF UDFs](examples/ptf_udf_timer_driven/java/remote-debugging-flink-ptf_udf_timer_driven.md).

Deploy first: `make deploy-cp-ptf-udf-timer-driven`, and then:

<details>
<summary>1. Set a breakpoint</summary>

Open [`SessionTimeoutDetector.java`](examples/ptf_udf_timer_driven/java/app/src/main/java/ptf/SessionTimeoutDetector.java) and click in the gutter at the first line of the `eval()` method:

```java
String eventType = input.getFieldAs("event_type");
```

Or, to debug the unnamed timer UDF, open [`PerEventFollowUp.java`](examples/ptf_udf_timer_driven/java/app/src/main/java/ptf/PerEventFollowUp.java) and set a breakpoint at:

```java
String eventType = input.getFieldAs("event_type");
```

Or, to debug the Abandoned Cart Detector, open [`AbandonedCartDetector.java`](examples/ptf_udf_timer_driven/java/app/src/main/java/ptf/AbandonedCartDetector.java) and set a breakpoint at:

```java
String action = input.getFieldAs("action");
```

Or, to debug the SLA Monitor, open [`SlaMonitor.java`](examples/ptf_udf_timer_driven/java/app/src/main/java/ptf/SlaMonitor.java) and set a breakpoint at:

```java
String status = input.getFieldAs("status");
```

Or, to debug a timer callback, set a breakpoint in `onTimer()` of any UDF.

</details>

<details>
<summary>2. Attach the debugger</summary>

Select the **"Attach to Flink TaskManager (Timer-Driven)"** configuration.

- **VS Code:** Open the **Run and Debug** panel (⇧⌘D), select the configuration from the dropdown, and press **F5**
- **IntelliJ IDEA:** Open the **Run/Debug Configurations** dropdown (top-right toolbar), select the configuration, and click **Debug** (⌃D / Shift+F9)

</details>

<details>
<summary>3. Send a test event</summary>

Produce a single JSON message to the `user_activity` topic to trigger the breakpoint:

```bash
make produce-user-activity-record
```

</details>

<details>
<summary>4. Debug</summary>

Your IDE will pause at your breakpoint. Inspect `input`, `state`, and local variables, step through the timer registration logic, and watch `state.eventCount` and `state.lastEventType` update as you step over lines.

> **Timer debugging tip:** Timers fire when the watermark advances past the timer's registered time. While paused at a breakpoint, watermarks don't advance, so `onTimer()` won't fire until you resume execution and let the watermark progress. For the unnamed timer UDFs (`PerEventFollowUp` and `SlaMonitor`), note that `onTimer()` fires once per event — not once per partition key. Both the `AbandonedCartDetector` and `SlaMonitor` demonstrate conditional output: `onTimer()` only emits if the cart wasn't checked out or the request wasn't resolved, respectively.

</details>

#### **3.1.2 Scalars**

##### **3.1.2.1 Debugging the Celsius to Fahrenheit Scalar UDF (`CelsiusToFahrenheit`)**

> For the full deep-dive, see [Remote Debugging `row-driven` Flink PTF UDFs](examples/scalar_udf/java/remote-debugging-flink-scalar_udf.md) (§1.2).
>
> The `CelsiusToFahrenheit` ships in the **same uber JAR** as `FahrenheitToCelsius`, so the same `make deploy-cc-scalar-udf` command and the same **"Attach to Flink TaskManager (scalar udf)"** debug configuration are used. The deploy script registers both Scalars as separate Flink SQL functions and starts an `INSERT INTO celsius_to_fahrenheit (sensor_id, celsius_temperature, fahrenheit_temperature) SELECT sensor_id, celsius_temperature, celsius_to_fahrenheit(celsius_temperature) FROM celsius_reading;` pipeline alongside the user-event enrichment job.

Deploy first: `make deploy-cc-scalar-udf`, and then:

<details>
<summary>1. Set a breakpoint</summary>

Open [`CelsiusToFahrenheit.java`](examples/scalar_udf/java/app/src/main/java/scalar_udf/CelsiusToFahrenheit.java) and click in the gutter at the first line of the `eval()` method:

```java
if (celsius == null)
```

</details>

<details>
<summary>2. Attach the debugger</summary>

Use the **same** **"Attach to Flink TaskManager (scalar udf)"** configuration as `CelsiusToFahrenheit` — both Scalars run in the same TaskManager pod from the same JAR. The IDE will [automatically port-forward](scripts/port-forward-taskmanager.sh) to the TaskManager pod and attach to the JDWP agent on port `5005`.

- **VS Code:** Open the **Run and Debug** panel (⇧⌘D), select the configuration from the dropdown, and press **F5**
- **IntelliJ IDEA:** Open the **Run/Debug Configurations** dropdown (top-right toolbar), select the configuration, and click **Debug** (⌃D / Shift+F9)

</details>

<details>
<summary>3. Send a test order</summary>

Produce a single JSON order to the `orders` topic to trigger the breakpoint:

```bash
make produce-celsius-reading-record
```

The sample record has two items in its comma-separated list, so `eval()` will run once and emit a Fahrenheit value.

</details>

<details>
<summary>4. Debug</summary>

Your IDE will pause at your breakpoint. Inspect `input`, then return the calculated Fahrenheit value.

</details>

---

## **4.0 Resources**

### **4.1 Confluent for Kubernetes (CfK)**
- [Manage Confluent Platform with Confluent for Kubernetes](https://docs.confluent.io/operator/current/co-manage-overview.html)
- [Minikube](https://minikube.sigs.k8s.io/docs/)

### **4.2 Confluent Platform for Apache Flink**
- [Stream Processing with Confluent Platform for Apache Flink](https://docs.confluent.io/cp-flink/current/overview.html)
- [Architecture and Features of Confluent Platform for Apache Flink](https://docs.confluent.io/cp-flink/current/concepts/overview.html#)
- [Get Started with Confluent Platform for Apache Flink](https://docs.confluent.io/platform/current/flink/get-started/overview.html)

### **4.3 Confluent Cloud for Apache Flink (CCAF)**
- [Stream Processing with Confluent Cloud for Apache Flink](https://docs.confluent.io/cloud/current/flink/overview.html)
- [Get Started with Confluent Cloud for Apache Flink](https://docs.confluent.io/cloud/current/flink/get-started/overview.html)
- [User-defined Functions in Confluent Cloud for Apache Flink](https://docs.confluent.io/cloud/current/flink/concepts/user-defined-functions.html)
