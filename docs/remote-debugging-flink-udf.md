# Remote Debugging a Flink UDF

Flink TaskManagers are JVM processes, so you can enable **Java remote debugging (JDWP)** and attach VSCode to them.

**Table of Contents**
<!-- toc -->
- [**1.0 Quick Start**](#10-quick-start)
- [**2.0 How It Works**](#20-how-it-works)
  - [**2.1 JDWP on the Flink TaskManager**](#21-jdwp-on-the-flink-taskmanager)
  - [**2.2 Supplemental RBAC**](#22-supplemental-rbac)
  - [**2.3 Port Forwarding (automated)**](#23-port-forwarding-automated)
  - [**2.4 VSCode Debug Configuration**](#24-vscode-debug-configuration)
- [**3.0 Important Caveats**](#30-important-caveats)
- [**4.0 For Confluent Cloud**](#40-for-confluent-cloud)
<!-- tocstop -->

---

> JDWP is already enabled on the TaskManager, the VSCode launch config is in place, and port-forwarding is automated as a pre-launch task. Once your cluster is running and your UDF is deployed, use the **"Attach to Flink TaskManager"** debug configuration to attach to the remote JVM and hit your breakpoints.
>
> **Note:** Pressing **F5** without selecting the correct configuration will attempt to *launch* a local Java process, which fails because UDFs have no `main()` method. Instead, open the **Run and Debug** panel (⇧⌘D), select **"Attach to Flink TaskManager"** from the dropdown, and then press **F5** (or click the green play button). This *attaches* the debugger to the already-running Flink TaskManager over JDWP on port `5005`.

## **1.0 Quick Start**

1. **Deploy** the full stack and your UDF:

    ```bash
    make cp-up               # Confluent Platform + Kafka UI
    make flink-up            # Flink Operator + CMF + Flink session cluster
    make deploy-cp-ptf-udf   # Build UDF JAR, copy to Flink pods, submit SQL
    ```

2. **Set a breakpoint** in your UDF — open `UserEventEnricher.java` and click in the gutter at the first line of the `eval()` method:

    ```java
    String eventType = input.getFieldAs("event_type");
    ```

3. In VSCode, open **Run and Debug** (⇧⌘D) and select **"Attach to Flink TaskManager"** from the configuration dropdown

4. Press **F5** — VSCode will port-forward to the TaskManager pod automatically and attach the debugger

5. **Send a test event** to trigger the breakpoint:

    ```bash
    make produce-user-events-record
    ```

6. **Debug** — VSCode pauses at your breakpoint. Inspect `input`, `state`, and local variables, step through the session logic, and watch `state.sessionId` and `state.eventCount` update as you step over lines.

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

A VSCode pre-launch task (`.vscode/tasks.json`) runs a helper script (`.vscode/port-forward-taskmanager.sh`) that:

1. Kills any existing port-forward on port `5005`
2. Discovers the TaskManager pod by label (`component=taskmanager`)
3. Starts `kubectl port-forward` in the background (detached via `nohup`/`disown` so it survives after the task shell exits)
4. Waits for port `5005` to be listening
5. Exits with success — VSCode then proceeds to attach the debugger

```json
{
    "label": "Port Forward Flink TaskManager",
    "type": "shell",
    "command": "${workspaceFolder}/.vscode/port-forward-taskmanager.sh"
}
```

If you need to port-forward manually (e.g., outside VSCode):

```bash
kubectl port-forward -n confluent <taskmanager-pod> 5005:5005
```

### **2.4 VSCode Debug Configuration**

The launch config (`.vscode/launch.json`) attaches to `localhost:5005` with a `preLaunchTask` that triggers the port-forward:

```json
{
  "type": "java",
  "name": "Attach to Flink TaskManager",
  "request": "attach",
  "hostName": "localhost",
  "port": 5005,
  "projectName": "app",
  "preLaunchTask": "Port Forward Flink TaskManager"
}
```

The `projectName` is `"app"` because that is the Gradle subproject name defined in `examples/ptf_udf/java/settings.gradle.kts`. This tells the debugger which classpath and source roots to use for resolving breakpoints.

## **3.0 Important Caveats**

- **TaskManager must be running** — the TaskManager pod only exists while a Flink job is active. Deploy your UDF first (`make deploy-cp-ptf-udf`) before attaching the debugger
- **Source must match** — the local code you have open in VSCode must match the JAR deployed to the cluster, or breakpoints won't align
- **Timeouts** — pausing too long at a breakpoint can trigger Flink's heartbeat timeout, causing the TaskManager to be considered dead. The `heartbeat.timeout` is already set to `5 minutes` in the Flink config
- **Single TaskManager** — if you have multiple TaskManagers, you're only attached to one. Debug with `parallelism=1` to keep things simple
- **`suspend=y`** is useful if you need to debug the `open()` lifecycle method, since it pauses the JVM before any processing starts

## **4.0 For Confluent Cloud**

_Remote debugging is **NOT POSSIBLE** on Confluent Cloud — you don't have access to the underlying JVMs. For that environment, stick with local MiniCluster integration tests or logging._