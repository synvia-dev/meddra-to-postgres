# Medical Dictionary Tools

Builds PostgreSQL databases from the raw MedDRA and WHODrug distributions. These databases
are what the eCRF's Medical Coding module reads — it only ever queries them, never writes.

* MedDRA: <https://meddra.com/> — one distribution per translation, released twice a year
* WHODrug: <https://who-umc.org/whodrug/> — one distribution, released twice a year

Both require subscription credentials to download. Each version gets its own database, and
versions coexist side by side; nothing is ever migrated in place.

| Dictionary | Database | Built by |
| --- | --- | --- |
| MedDRA, Portuguese | `meddra_<version>` (e.g. `meddra_290`) | `sh/Go_meddra_DbCreate.sh` |
| MedDRA, English | `meddra_<version>_en` | `sh/Go_meddra_DbCreate.sh` with `MEDDRA_LANG=en` |
| WHODrug Global C3 | `whodrug_<YYMM>` (e.g. `whodrug_2603`) | `sh/Go_whodrug_DbCreate.sh` |

## Quick start

```bash
docker compose up -d    # PostgreSQL on localhost:5433
```

Defaults: user `meddict`, password `meddict`, database `medical-coding` —
`postgresql://meddict:meddict@localhost:5433/medical-coding`. The dictionary databases are
created alongside it, not inside it.

Python packages, needed **only for the MedDRA import** (the WHODrug scripts are stdlib-only):

```sh
python3 -m pip install BioClients psycopg2-binary pandas
```

`BioClients` declares no dependencies, so `pandas` will not come in on its own — without it
the load fails table by table with `ModuleNotFoundError`. `meddra_utils.py` imports
`psycopg2` at module load even for the pure conversion steps, so it is required too;
`psycopg2-binary` avoids needing a local `pg_config` to build.

Only `Go_meddra_DbCreate.sh` and `Go_whodrug_DbCreate.sh` are part of this workflow. The
other `sh/Go_meddra_*` scripts are upstream leftovers — three of them target a hardcoded
`meddra` database that this repo never creates.

---

## MedDRA

1. Copy the distribution's `.asc` files into `data/MedAscii/`
2. Put the version in `LATEST_RELEASE.txt` (e.g. `29.0`)
3. Run:

```sh
# Portuguese -> meddra_290
./sh/Go_meddra_DbCreate.sh

# English -> meddra_290_en
MEDDRA_LANG=en ./sh/Go_meddra_DbCreate.sh
```

### Languages

The eCRF resolves the database per study as `meddra_<version>[_<lang>]`, where the
**unsuffixed** name is the Portuguese load. So `MEDDRA_LANG` is empty for Portuguese and
`en` for English — it accepts only suffixes the eCRF knows how to resolve (today: `en`), is
lowercased before use, and rejects `pt` on purpose.

**Every new version has to be loaded in both languages.** Studies pick their dictionary
language individually and the eCRF deliberately refuses to fall back to another one, so a
version that exists in only one language breaks Medical Coding for every study on the
other. Provisioning a release means two runs.

`data/MedAscii/` holds one distribution at a time, so swap the `.asc` files between runs.
**The two distributions are not shaped the same:** the English one ships them in
`MedAscii/`, the Brazilian Portuguese one in `ascii-<version>/`. Both go to
`data/MedAscii/`, so the Portuguese copy is a rename:

```sh
cp -R <dist>/MedAscii        data/MedAscii   # English
cp -R <dist>/ascii-<version> data/MedAscii   # Portuguese, e.g. ascii-281 for 28.1
```

The Portuguese files are **Latin-1 with CRLF** where the English ones are ASCII. Already
handled — `meddra_utils.py` reads `latin-1` and writes UTF-8, which is why the Portuguese
databases have correct accents. Do not "fix" it to UTF-8.

### Safety rails

The load is destructive: it **drops** the target database before rebuilding. Two
independent checks stand in front of it, because the two ways to get this wrong fail very
differently.

- **Wrong database.** If the target already exists, the script aborts. Pass
  `MEDDRA_DB_OVERWRITE=1` to rebuild on purpose. This is what keeps a forgotten
  `MEDDRA_LANG` — which resolves to the *unsuffixed* name — from wiping the live Portuguese
  database that studies are reading.
- **Wrong content.** Before converting anything, the script reads
  `data/MedAscii/meddra_release.asc` (the distribution stamps it as
  `<version>$<language>$$$$`) and refuses to run if either disagrees with the target. A
  stale `data/MedAscii` otherwise builds the *right* database name with the wrong terms,
  which raises no error at all and surfaces weeks later as a coder who cannot find their
  own terms.

### Hierarchy

```
SOC  = System Organ Class
HLGT = High Level Group Term
HLT  = High Level Term
PT   = Preferred Term
LLT  = Lowest Level Term
```

`llt.current` marks whether a term is current, stored as `TRUE`/`FALSE` (converted from the
distribution's `Y`/`N`). Consumers must treat anything else as non-current.

---

## WHODrug C3

1. Copy the C3 CSV files into `data/WHODrugC3/`:
   `MP.csv`, `ThG.csv`, `ING.csv`, `SUN.csv`, `ATC.csv`, `PF.csv`, `STR.csv`, `ORG.csv`,
   `SRCE.csv`, `CCODE.csv`, `PRT.csv`, `UNIT.csv`, `Version.csv`
2. Put the version code in `LATEST_WHODRUG_RELEASE.txt` (`YYMM`, e.g. `2603` for March 2026)
3. Run:

```sh
./sh/Go_whodrug_DbCreate.sh
```

WHODrug has no language axis — one database per version, no suffix.

> This script does **not** yet have the guards described above for MedDRA: it drops the
> target without checking, and its `psql` calls omit `-d postgres`. Take care pointing it
> at a shared server.

### Indexes

`Go_whodrug_DbCreate.sh` applies `sql/whodrug_indexes.sql` automatically after the load.
The strategy is **prefix-anchored btree**, not trigram: lookups are
`lower(drug_name) LIKE 'term%'` and exact match on `drug_rec_no || seq1 || seq2`. Substring
search is intentionally unsupported on the hot path.

A database built before that switch carries the old trigram set. Retrofit it with
`psql -d whodrug_<YYMM> -f sql/whodrug_indexes_v2.sql` — idempotent, and safe to run
online, since WHODrug is read-only at runtime. Check `pg_indexes` on the live database
rather than assuming which set it has.

### Tables

Row counts are the actual `whodrug_2603` (March 2026) figures, for sanity-checking a load.

| Table | Description | Rows |
|-------|-------------|------|
| `mp` | Medicinal Products (main table) | 5,596,868 |
| `thg` | Therapeutic Groups (ATC assignments) | 6,035,124 |
| `ing` | Ingredients | 9,041,517 |
| `sun` | Substances | 28,540 |
| `atc` | ATC Classification (5 levels) | 1,457 |
| `pf` | Pharmaceutical Forms | 226 |
| `str` | Strengths/Dosages | 18,070 |
| `org` | Organizations (manufacturers) | 92,073 |
| `srce` | Sources/References | 508 |
| `ccode` | Country Codes (ISO 3166-1) | 250 |
| `prt` | Product Types | 10 |
| `unit` | Units of Measurement | 84 |
| `version` | Dataset version info | 1 |

### Hierarchy

```
MP (Medicinal Products)
  --> THG (Therapeutic Groups) --> ATC (Classification, 5 levels)
  --> ING (Ingredients) --> SUN (Substances)
  --> PF (Pharmaceutical Forms)
  --> STR (Strengths)
  --> ORG (Organizations)
  --> CCODE (Countries)
  --> PRT (Product Types)
```

The drug code is composed, not stored:

```sql
SELECT record_id, drug_name, drug_rec_no || seq1 || seq2 AS drug_code
FROM mp
WHERE lower(drug_name) LIKE 'paracetamol%'
LIMIT 20;
```

---

## Loading onto a shared server

The scripts read standard `PG*` variables, so they will happily target a remote host:

```sh
PGHOST=<host> PGPORT=5432 PGUSER=<user> PGPASSWORD=<pass> \
  MEDDRA_LANG=en ./sh/Go_meddra_DbCreate.sh
```

**Prefer building locally and shipping a dump.** The create scripts drop their target, so
pointing them straight at a server that hosts live dictionaries puts those databases one
typo away from a rebuild. Build against the local container, verify, then:

```sh
pg_dump --no-privileges -Fc -d meddra_290_en > meddra_290_en.pgdump

createdb -h <host> -U <user> meddra_290_en
pg_restore -h <host> -U <user> -e -O -x -d meddra_290_en meddra_290_en.pgdump
```

`-O -x` drops the dump's owner and privileges so the objects end up owned by the restoring
role. Note that `pg_dump -Fc` does not carry the database-level `COMMENT`, so re-apply it
on the target if you want it.

Verify a restore by comparing structure and row counts against the previous version of the
same dictionary — they should match column for column, and the row counts should match the
`.asc` inputs.

---

## Configuration

Two separate sets of variables, which is easy to confuse:

| Variables | Consumed by | Effect |
| --- | --- | --- |
| `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` | `docker-compose.yml` | How the local container is provisioned. Applied by `initdb` on the **first** `up` only — once the volume exists, changing them does nothing. |
| `POSTGRES_PORT` | `docker-compose.yml` | Host port mapped to the container (default `5433`). Applied on every `up`. |
| `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` | the `sh/` scripts and `psql` | Where the scripts connect. |

Changing the `POSTGRES_*` set does **not** change where the scripts connect; you have to set
the `PG*` set to match. A `.env` file works for either.

```bash
docker compose down    # stop the local container
```
