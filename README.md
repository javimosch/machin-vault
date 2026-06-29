# machin-vault

A single self-hostable binary that backs up your files and databases — and, when
something is lost, lets an **agent recover it in one glance**. CLI-first and
agent-friendly (JSON in/out, semantic exit codes), with a built-in reactive web
dashboard served from the same binary.

```
$ machin-vault list
{"version":"1","ok":true,"targets":[
  {"name":"orders-db","kind":"postgres","count":14,"versions":[
    {"v":"2026-06-29T03:00:01Z","age":"6h","size":210452992,"sha":"58c9d2d71b6c","encrypted":true,"file":"..."},
    ...]}]}
```

No agent, no daemon, no cron required to read a backup — it's just files on disk
named so the whole history is legible: `<store>/<target>/<name>_<unixtime>_<sha>.<ext>`.

## The recovery use case

> "My database is gone — can you get it back?"

```bash
machin-vault list orders-db                 # 1. glance: newest is 6h old, sha 58c9d2d7
machin-vault get orders-db --to /tmp/rec     # 2. drop the raw artifact somewhere safe
machin-vault unpack orders-db --to /tmp/rec  # 3. or decrypt + decompress it to inspect
machin-vault restore orders-db --yes         # 4. restore via the db's native tool
```

Every command answers in one JSON object an agent can act on. `restore` is the only
destructive one and refuses to run without `--yes`.

## Agent-first contract

- **Self-describing:** `machin-vault help-json` lists every command, flag, and exit code.
- **Versioned output:** every response is `{"version":"1","ok":...}` on stdout; errors are
  `{"version":"1","ok":false,"error":"..."}` on stderr.
- **Semantic exit codes:** `0` ok · `80-89` bad input · `90-99` not found · `100-109`
  integration (ssh/dump/restore failed) · `110-119` internal.
- **Non-interactive:** destructive actions need an explicit `--yes`.

## What it backs up

| kind       | how                                              | restore                          |
|------------|--------------------------------------------------|----------------------------------|
| `file`     | `rsync` a path (local or `host:/path`)           | rsync back                       |
| `postgres` | `pg_dump \| gzip` (optionally over ssh)          | `gunzip \| psql`                 |
| `mysql`    | `mysqldump \| gzip` (optionally over ssh)        | `gunzip \| mysql`                |
| `mongo`    | `mongodump --archive --gzip`                     | `mongorestore --archive --drop`  |
| `custom`   | any shell command that writes the artifact       | any shell command that reads it  |

machin-vault **orchestrates the real tools** — it never reimplements them. Add
`"container": "pg"` to a target to run the dump inside `docker exec`.

Built-in: **content-addressed dedup** (an unchanged backup is skipped), **retention**
(keep the newest N per target), and optional **at-rest encryption** (`openssl
aes-256-cbc`, set `encrypt_password`).

## The dashboard (same binary)

```bash
machin-vault -c vault.json serve --port 8080
```

Serves a reactive dashboard at `http://localhost:8080`: server-rendered HTML that
works with zero JavaScript (the recovery glance), progressively enhanced by a wasm
client compiled from the same source — "Backup now" per target with live status.
The binary serves its own `/app.wasm` and a JSON API (`/api/list`, `/api/backup?t=`).

## Quickstart

```bash
cp vault.json.example vault.json   # edit your targets
./build.sh                         # builds app.wasm + the machin-vault binary
./machin-vault -c vault.json backup        # back up everything now
./machin-vault -c vault.json list          # see what you have
```

Schedule it with plain cron — the tool is stateless, so a bare
`machin-vault -c /etc/vault.json backup` is all a cron line needs.

## Build

Needs [machin](https://github.com/javimosch/machin) **v0.83.0+** (for the `exec`
builtin) and [`zig`](https://ziglang.org) for the wasm client. Then:

```bash
MACHIN=/path/to/machin ./build.sh
```

The whole thing is ~600 lines of [MFL](https://github.com/javimosch/machin) across
`src/` — the CLI, the HTTP server, the JSON API, and the reactive UI, with **zero
runtime dependencies** in the shipped binary. It's a dogfooding tool for machin: a
real product the language had to be good enough to build.

## Config reference

See [`vault.json.example`](./vault.json.example). Per target: `name`, `kind`,
`retention` (default 7), plus kind-specific fields (`source` / `ssh` / `db` / `user`
/ `password` / `container` / `command` / `restore`). Top level: `store` (where
artifacts live) and `encrypt_password` (empty = no encryption).

> Your real `vault.json` holds credentials — it's gitignored. Commit only the example.
