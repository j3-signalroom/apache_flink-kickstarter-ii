# **Remote Server Setup (SSH Tunneling)**

You need two things: a terminal on the remote to run `make` targets, and an SSH tunnel to reach the UIs from your local browser.

<details>
<summary>Step 0 — Authorize your local machine's SSH public key on the remote server</summary>

On the remote server, append your local machine's public key to the authorized keys file so you can connect without a password:

```bash
echo "your-public-key-string" >> ~/.ssh/[file-name]
```

Replace `your-public-key-string` with the contents of your local `~/.ssh/[file-name].pub` (e.g., `cat ~/.ssh/ssh-key-dev-cloud-server-access.pub` on your Mac), and `[file-name]` with the name of your authorized keys file (typically `authorized_keys`).

For example:

```bash
echo "ssh-ed25519 AAAA...your-key... user@macbook" >> ~/.ssh/authorized_keys
```

Then make sure permissions are correct on the remote:

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

</details>

<details>
<summary>Step 1 — Add an entry to `~/.ssh/config` on your local machine</summary>

```
Host [label for the remote server]
  HostName [IP address]
  User root
  IdentityFile ~/.ssh/ssh-key-dev-cloud-server-access
  IdentitiesOnly yes
  LocalForward 9021 localhost:9021
  LocalForward 8081 localhost:8081
  LocalForward 8080 localhost:8080
```

The three `LocalForward` lines tunnel the UI ports from the remote server to your local machine automatically every time you connect.
</details>

<details>
<summary>Step 2 — Terminal 1: bring up the stack on the remote</summary>

```bash
ssh [label for the remote server]
cd /path/to/apache_flink-kickstarter-ii
make cp-up
make flink-up
```
</details>

<details>
<summary>Step 3 — Terminal 2: open the SSH tunnel</summary>

```bash
ssh [label for the remote server]
```

Connecting activates the `LocalForward` rules. No extra flags needed.
</details>

<details>
<summary>Step 4 — Open the UIs in your local browser</summary>

| URL | UI |
|-----|----|
| `http://localhost:9021` | Confluent Control Center |
| `http://localhost:8081` | Apache Flink UI |

> The port-forwards on the remote side are started by `make c3-open` and `make flink-ui` (called internally by `make cp-up` / `make flink-up`). The SSH `LocalForward` simply bridges your laptop to those already-listening ports on the remote.
</details>
