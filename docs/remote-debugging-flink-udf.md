# Remote Debugging a Flink UDF

Flink TaskManagers are JVM processes, so you can enable **Java remote debugging (JDWP)** and attach VSCode to them.

**Table of Contents**
<!-- toc -->
- [Quick Start](#quick-start)
- [How It Works](#how-it-works)
  - [JDWP on the Flink TaskManager](#jdwp-on-the-flink-taskmanager)
  - [Port Forwarding (automated)](#port-forwarding-automated)
  - [VSCode Debug Configuration](#vscode-debug-configuration)
- [Important Caveats](#important-caveats)
- [For Confluent Cloud](#for-confluent-cloud)
<!-- tocstop -->

---

> JDWP is already enabled on the TaskManager, the VSCode launch config is in place, and port-forwarding is automated as a pre-launch task. Once your cluster is running, just hit **F5**, if you want to debug your UDF.

## Quick Start

1. **Deploy** the FlinkDeployment to your Minikube cluster
2. **Set breakpoints** in your UDF (e.g., `UserEventEnricher.java`)
3. **F5** in VSCode → select **"Attach to Flink TaskManager"**
4. Send events to your `user_events` topic — the debugger will pause at your breakpoints

That's it. The port-forward to the TaskManager pod starts automatically as a VSCode pre-launch task.

## How It Works

### JDWP on the Flink TaskManager

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

### Port Forwarding (automated)

A VSCode background task (`.vscode/tasks.json`) automatically discovers the TaskManager pod and starts port-forwarding when you launch the debugger:

```bash
kubectl port-forward -n confluent $(kubectl get pods -n confluent -l component=taskmanager -o jsonpath='{.items[0].metadata.name}') 5005:5005
```

If you need to do this manually (e.g., outside VSCode):

```bash
kubectl port-forward -n confluent <taskmanager-pod> 5005:5005
```

### VSCode Debug Configuration

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

## Important Caveats

- **Source must match** — the local code you have open in VSCode must match the JAR deployed to the cluster, or breakpoints won't align
- **Timeouts** — pausing too long at a breakpoint can trigger Flink's heartbeat timeout, causing the TaskManager to be considered dead. The `heartbeat.timeout` is already set to `5 minutes` in the Flink config
- **Single TaskManager** — if you have multiple TaskManagers, you're only attached to one. Debug with `parallelism=1` to keep things simple
- **`suspend=y`** is useful if you need to debug the `open()` lifecycle method, since it pauses the JVM before any processing starts

## For Confluent Cloud

Remote debugging is **not possible** on Confluent Cloud — you don't have access to the underlying JVMs. For that environment, stick with local MiniCluster integration tests or logging.
