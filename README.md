# backup-cron

Back up Postgres databases running in a Docker container, from crontab. Keeps the
newest N backups per database (default 3).

## Requirements

- `docker`, `jq`, `flock` on the host
- The user running it needs Docker access and write access to `target_dir`

## Setup

```bash
cp backup-config.example.json backup-config.json
chmod +x backup-postgres.sh
```

Edit `backup-config.json`:

```json
{
  "container": "my-postgres-container",
  "db_user": "postgres",
  "target_dir": "/var/backups/postgres",
  "retain": 3,
  "databases": ["app_production", "app_reporting"]
}
```

| Key          | Required | Default    | Notes                                  |
|--------------|----------|------------|----------------------------------------|
| `container`  | yes      |            | Name or ID of the Postgres container   |
| `db_user`    | no       | `postgres` | Must be a role that exists in Postgres |
| `target_dir` | yes      |            | Created if missing                     |
| `retain`     | no       | `3`        | Backups kept per database              |
| `databases`  | yes      |            | Databases to back up                   |

## Usage

```bash
./backup-postgres.sh                     # uses backup-config.json next to the script
./backup-postgres.sh /path/to/config.json
```

Crontab (`crontab -e`), every hour on the hour:

```
0 * * * * /home/roland/playground/backup-cron/backup-postgres.sh >> /var/log/pg-backup.log 2>&1
```

With hourly runs, `retain` is how many hours of history you keep: `3` covers the
last 3 hours, `24` covers a day.

## How it works

- Backups go to `<target_dir>/<db>/<db>_<UTC timestamp>.dump` in `pg_dump`'s
  custom format (`-Fc`, compressed).
- Each dump is written to a `.partial` file and checked with `pg_restore --list`
  before it is renamed into place.
- Old backups are pruned only after a new one succeeds, so a failing backup
  never drops you below `retain`.
- If one database fails, the rest still run; the script exits `1`.
- A lock file stops overlapping runs.

## Restore

```bash
docker exec -i <container> pg_restore -U postgres -d <db> --clean < /var/backups/postgres/<db>/<file>.dump
```
