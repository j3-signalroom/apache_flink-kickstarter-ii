# Remote Debugging Flink Scalar UDFs

Flink TaskManagers are JVM processes, so you can enable **Java remote debugging (JDWP)** and attach your IDE (VS Code or IntelliJ IDEA) to them.

This guide covers both scalar UDFs in this package: **`CelsiusToFahrenheit`** and **`FahrenheitToCelsius`**. Because both UDFs ship in the same uber JAR, run inside the same TaskManager pod, and live in the same Gradle subproject (`app`), they share **one** debug configuration: **"Attach to Flink TaskManager (`scalar-udf`)"**. The only thing that differs between debugging the two is *where* you set the breakpoint and *which* source Kafka topic you publish a record to.

**Table of Contents**
<!-- toc -->
- [**1.0 Quick Start**](#10-quick-start)
  - [**1.1 Common setup (do this once)**](#11-common-setup-do-this-once)
  - [**1.2 Debugging `CelsiusToFahrenheit`**](#12-debugging-celsiustofahrenheit)
  - [**1.3 Debugging `FahrenheitToCelsius`**](#13-debugging-fahrenheittocelsius)
- [**2.0 How It Works**](#20-how-it-works)
  - [**2.1 JDWP on the Flink TaskManager**](#21-jdwp-on-the-flink-taskmanager)
  - [**2.2 Supplemental RBAC**](#22-supplemental-rbac)
  - [**2.3 Port Forwarding (automated)**](#23-port-forwarding-automated)
  - [**2.4 IDE Debug Configurations**](#24-ide-debug-configurations)
    - [**2.4.1 VS Code (`.vscode/launch.json`)**](#241-vs-code-vscodelaunchjson)
    - [**2.4.2 IntelliJ IDEA (`.idea/runConfigurations/`)**](#242-intellij-idea-idearunconfigurations)
- [**3.0 Important Caveats**](#30-important-caveats)
- [**4.0 For Confluent Cloud**](#40-for-confluent-cloud)
<!-- tocstop -->

---

> JDWP is already enabled on the TaskManager, debug configurations for both VS Code and IntelliJ IDEA are in place, and port-forwarding is automated as a pre-launch task. Once your cluster is running and the UDFs are deployed, use the **"Attach to Flink TaskManager (`scalar-udf`)"** debug configuration to attach to the remote JVM and hit your breakpoints in *either* `CelsiusToFahrenheit.java` or `FahrenheitToCelsius.java`.
>
> **Note:** Make sure you select the **"Attach to Flink TaskManager (`scalar-udf`)"** configuration before launching the debugger. Starting a *launch* (rather than *attach*) configuration will attempt to run a local Java process, which fails because UDFs have no `main()` method.
>
> - **VS Code:** Open the **Run and Debug** panel (⇧⌘D), select **"Attach to Flink TaskManager (`scalar-udf`)"** from the dropdown, then press **F5**.
> - **IntelliJ IDEA:** Open the **Run/Debug Configurations** dropdown (top-right toolbar), select **"Attach to Flink TaskManager (`scalar-udf`)"**, then click **Debug** (⌃D / Shift+F9).

## **1.0 Quick Start**

### **1.1 Common setup (do this once)**

These steps are identical for both UDFs — `make deploy-cp-scalar-udf` builds the uber JAR and registers **both** functions (`celsius_to_fahrenheit` and `fahrenheit_to_celsius`) in the same Flink SQL session, then starts both `INSERT INTO ... SELECT ...` pipelines.

1. **Deploy** the full stack and the UDFs:

    ```bash
    make cp-up                     # Confluent Platform
    make flink-up                  # Flink Operator + CMF + Flink session cluster
    make deploy-cp-scalar-udf      # Build UDF JAR, copy to Flink pods, submit SQL
    ```

2. Select the **"Attach to Flink TaskManager (`scalar-udf`)"** debug configuration in your IDE:

    - **VS Code:** Open **Run and Debug** (⇧⌘D) and choose it from the dropdown
    - **IntelliJ IDEA:** Choose it from the **Run/Debug Configurations** dropdown (top-right toolbar)

3. **Start the debugger** — your IDE will port-forward to the TaskManager pod automatically, then attach:

    - **VS Code:** Press **F5**
    - **IntelliJ IDEA:** Click **Debug** (⌃D / Shift+F9)

4. Now follow §1.2 *or* §1.3 below depending on which UDF you want to debug. You can switch between the two without restarting the debugger — just set a breakpoint in the other file and produce a record to its source topic.

### **1.2 Debugging `CelsiusToFahrenheit`**

1. **Set a breakpoint** — open `CelsiusToFahrenheit.java` and click in the gutter at the first executable line of the `eval()` method:

    ```java
    if (celsius == null)
        return null;
    ```

    Or, to inspect the computed result, set a breakpoint on the return expression:

    ```java
    return (celsius * 9.0 / 5.0) + 32.0;
    ```

2. **Send a test reading** to trigger the breakpoint — the initial `INSERT INTO celsius_reading VALUES (...)` from the deploy script seeds six rows that all hit `eval()` once each. To fire the breakpoint again, publish an additional record to the `celsius_reading` topic:

    ```bash
    kubectl exec -n confluent kafka-0 -- \
        sh -c 'echo "{\"sensor_id\":1006,\"celsius_temperature\":30}" | \
               kafka-console-producer --bootstrap-server kafka:9071 --topic celsius_reading'
    ```

3. **Debug** — your IDE pauses at your breakpoint. Inspect `celsius`, step over the null check, and watch the computed Fahrenheit value on the return line. Because this is a scalar UDF, every call to `eval()` is independent — there is no state to inspect between invocations, and no keying to reason about. Producing the same record twice produces identical results (determinism in action).

### **1.3 Debugging `FahrenheitToCelsius`**

1. **Set a breakpoint** — open `FahrenheitToCelsius.java` and click in the gutter at the first executable line of the `eval()` method:

    ```java
    if (fahrenheit == null)
        return null;
    ```

    Or, to inspect the computed result, set a breakpoint on the return expression:

    ```java
    return (fahrenheit - 32) * 5.0 / 9.0;
    ```

2. **Send a test reading** to trigger the breakpoint — the initial `INSERT INTO fahrenheit_reading VALUES (...)` from the deploy script seeds six rows that all hit `eval()` once each. To fire the breakpoint again, publish an additional record to the `fahrenheit_reading` topic:

    ```bash
    kubectl exec -n confluent kafka-0 -- \
        sh -c 'echo "{\"sensor_id\":2006,\"fahrenheit_temperature\":86}" | \
               kafka-console-producer --bootstrap-server kafka:9071 --topic fahrenheit_reading'
    ```

3. **Debug** — your IDE pauses at your breakpoint. Inspect `fahrenheit`, step over the null check, and watch the computed Celsius value on the return line. The UDF mirrors `CelsiusToFahrenheit` structurally: one input, one output, no state, no side effects.

## **2.0 How It Works**

### **2.1 JDWP on the Flink TaskManager**

> JDWP (Java Debug Wire Protocol) is the protocol used for communication between a debugger (like VS Code or IntelliJ) and a Java Virtual Machine (JVM) being debugged. It's part of the Java Platform Debugger Architecture (JPDA).
>
> Key points:
>
> - **Purpose:** Defines the format of requests and replies between the debugger front-end and the JVM.
> - **Transport:** Typically runs over a socket connection (TCP/IP), which is what enables **remote debugging** — the debugger and JVM can be on different machines.
> - **How it's enabled:** You pass JVM arguments like:
>
>   `-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005`
>   - `transport=dt_socket` — use TCP sockets
>   - `server=y` — the JVM listens for a debugger to attach
>   - `suspend=n` — don't pause the JVM on startup waiting for a debugger (`y` would pause)
>   - `address=*:5005` — listen on port `5005`

The FlinkDeployment CR (`k8s/base/flink-basic-deployment.yaml`) includes the JDWP agent flag in the Flink configuration:

```yaml
flinkConfiguration:
  env.java.opts.taskmanager: "-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005"
  heartbeat.timeout: "300000"
```

- `suspend=n` — the JVM starts normally (use `suspend=y` if you need it to wait for the debugger before processing)
- `address=*:5005` — listens on port `5005`
- `heartbeat.timeout` — increased to `5 minutes` so pausing at breakpoints doesn't kill the TaskManager

### **2.2 Supplemental RBAC**

Flink's Kubernetes session-cluster executor needs to GET the JobManager REST service (e.g. `flink-basic-rest`) to submit jobs. The Helm-managed Role for the `flink` ServiceAccount grants access to pods, configmaps, and deployments — but **not services**.

The manifest `k8s/base/flink-rbac.yaml` fills this gap with a supplemental Role and RoleBinding:

```yaml
rules:
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["get", "list", "watch"]
```

This is additive — Kubernetes merges permissions across all Roles bound to the same subject, so the Helm-managed Role is unaffected. The `flink-rbac` Makefile target applies this manifest and runs automatically as a dependency of `flink-deploy`.

### **2.3 Port Forwarding (automated)**

Both IDEs run a helper script (`scripts/port-forward-taskmanager.sh`) as a pre-launch / "Before launch" step that:

1. Kills any existing port-forward on port `5005`
2. Discovers the TaskManager pod by label (`component=taskmanager`)
3. Starts `kubectl port-forward` in the background (detached via `nohup`/`disown` so it survives after the task shell exits)
4. Waits for port `5005` to be listening
5. Exits with success — the IDE then proceeds to attach the debugger

**VS Code** triggers the script via a task in `.vscode/tasks.json`:

```json
{
    "label": "Port Forward Flink TaskManager",
    "type": "shell",
    "command": "${workspaceFolder}/scripts/port-forward-taskmanager.sh"
}
```

**IntelliJ IDEA** triggers the same script via a Shell Script run configuration (`.idea/runConfigurations/Port_Forward_Flink_TaskManager.xml`) that is wired as a "Before launch" step in the debug configuration.

If you need to port-forward manually (e.g., outside your IDE):

```bash
kubectl port-forward -n confluent <taskmanager-pod> 5005:5005
```

### **2.4 IDE Debug Configurations**

Both IDEs ship a pre-configured **"Attach to Flink TaskManager (`scalar-udf`)"** remote debug configuration. The attach configuration wires the port-forward script as a pre-launch step so the entire flow is one click. The scalar-udf configuration differs from the row-driven / timer-driven variants only in its **source roots**, which point at this package's Java sources so breakpoints in `CelsiusToFahrenheit.java` and `FahrenheitToCelsius.java` resolve correctly.

#### **2.4.1 VS Code (`.vscode/launch.json`)**

```json
{
  "type": "java",
  "name": "Attach to Flink TaskManager (scalar-udf)",
  "request": "attach",
  "hostName": "localhost",
  "port": 5005,
  "projectName": "app",
  "sourcePaths": [
    "${workspaceFolder}/examples/scalar_udf/java/app/src/main/java"
  ],
  "preLaunchTask": "Port Forward Flink TaskManager"
}
```

The `projectName` is `"app"` because that is the Gradle subproject name defined in `examples/scalar_udf/java/settings.gradle.kts`. This tells the debugger which classpath and source roots to use for resolving breakpoints. Both `CelsiusToFahrenheit` and `FahrenheitToCelsius` live under the same `app` subproject, so this single configuration resolves breakpoints in either file with no additional setup.

#### **2.4.2 IntelliJ IDEA (`.idea/runConfigurations/`)**

IntelliJ run configurations are stored as XML and are automatically recognized when you open the project:

| Run Configuration | What it does |
|---|---|
| **Port Forward Flink TaskManager** | Shell Script config that runs `scripts/port-forward-taskmanager.sh` to `kubectl port-forward` port `5005` to the TaskManager pod |
| **Attach to Flink TaskManager (scalar-udf)** | Remote JVM Debug config that attaches to `localhost:5005` with the IntelliJ module set to `examples.scalar_udf.java.app.main`. The port-forward config runs automatically as a "Before launch" task |

> **Note:** The Shell Script run configuration requires the **Shell Script** plugin, which is bundled with IntelliJ IDEA 2020.2+.

## **3.0 Important Caveats**

- **TaskManager must be running** — the TaskManager pod only exists while a Flink job is active. Deploy the UDFs first (`make deploy-cp-scalar-udf`) before attaching the debugger
- **Source must match** — the local code you have open in your IDE must match the JAR deployed to the cluster, or breakpoints won't align
- **Timeouts** — pausing too long at a breakpoint can trigger Flink's heartbeat timeout, causing the TaskManager to be considered dead. The `heartbeat.timeout` is already set to `5 minutes` in the Flink config
- **Single TaskManager** — if you have multiple TaskManagers, you're only attached to one. Debug with `parallelism=1` to keep things simple
- **`suspend=y`** is useful if you need to debug the `open()` lifecycle method, since it pauses the JVM before any processing starts
- **Breakpoints fire on every row** — scalar UDFs are inlined into the scan-and-project pipeline, so your breakpoint will fire once for every input row that reaches the operator. If you publish a batch of records in quick succession you'll step through them one at a time — produce a single record when you want to inspect exactly one invocation
- **Determinism holds at breakpoints too** — stepping through `eval()` multiple times with the same input always yields the same output, so you can re-trigger a scenario by publishing an identical record without worrying about hidden state drift

## **4.0 For Confluent Cloud**

_Remote debugging is **NOT POSSIBLE** on Confluent Cloud — you don't have access to the underlying JVMs. For that environment, stick with [local MiniCluster integration tests](https://nightlies.apache.org/flink/flink-docs-stable/docs/dev/datastream/testing/#testing-flink-jobs) or logging._
