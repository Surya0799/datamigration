# Marketo Bulk Migration (Export → Dedupe → Chunk → Bulk Import)

End-to-end MuleSoft app that extracts leads from a **source** Marketo instance
(Bulk Export API), deduplicates by email, splits valid leads into 10-record CSV
chunks, and imports each chunk into a **target** Marketo instance (Bulk Import
API) via a File Listener — with error, retry, reprocess, and status tracking.

Built against the two Deloitte sandbox Postman collections
(instance `733-JCL-696.mktorest.com`).

---

## Components

| File | Role |
|------|------|
| `global.xml` | HTTP listener, source/target Marketo HTTP configs, one File config rooted at `data/` |
| `common.xml` | `get-source-token`, `get-target-token` OAuth sub-flows |
| `extract-dedupe-chunk.xml` | **Flow A** – export → dedupe → error.csv → chunk files |
| `import-listener.xml` | **Flow B** – File Listener → bulk import → status/failure handling |
| `dwl/dedupe.dwl` | splits records into `valid` winners + `errors` (with reasons) |
| `config.yaml` | folders, chunk size, Marketo creds/ids, retry tuning |

## Data folders (all auto-created under `data/`)

```
extract/     raw export CSV downloaded from source Marketo (archive)
source/      10-record chunk files  ← watched by the File Listener
inprogress/  chunk currently being imported (prevents re-pickup)
processed/   chunks that finished importing (success or data-failure)
reprocess/   chunks that hit connectivity errors + reprocess.csv
error/        error.csv  – duplicates, invalid emails, import data-failures
status/       status.csv – one tracking row per chunk
```

---

## End-to-end processing flow

### Phase 1 — Extract, deduplicate, chunk (Flow A)
Trigger: `POST http://localhost:8081/migrate`

1. **OAuth** – get an access token from source Marketo (`client_credentials`).
2. **Create export** – `POST /bulk/v1/leads/export/create.json` with the field
   list (`firstName,lastName,email,company,country`), `smartListId 1030`, `CSV`.
   Marketo returns an `exportId`.
3. **Enqueue** – `POST …/{exportId}/enqueue.json` starts the job.
4. **Poll** – `GET …/{exportId}/status.json` in an `until-successful` loop until
   the status is `Completed` (or `Failed` → error).
5. **Download** – `GET …/{exportId}/file.json` streams the CSV; it is archived to
   `extract/`.
6. **Parse + dedupe** (`dedupe.dwl`):
   - **INVALID_EMAIL** – blank/malformed email → `errors`.
   - **DUPLICATE_EMAIL** – same email more than once → keep the **most complete**
     record (most populated fields; ties keep the first seen); the rest → `errors`.
   - Survivors → `valid`.
7. **error.csv** – all rejected rows are written to `error/error.csv`, each with a
   `failureReason` column. The `error/` folder is created automatically.
8. **Chunk** – `valid` is split into arrays of **10** (`divideBy 10`) and each is
   written as `source/chunk-<runId>-<n>.csv`. The `source/` folder is created
   automatically.
9. **Response** – JSON summary: `{ totalExtracted, validLeads, rejected, chunkFiles }`.

### Phase 2 — Import each chunk (Flow B, File Listener)
Runs continuously; polls `source/` every 5s for `chunk-*.csv`.

1. **Pickup** – the listener reads a new chunk; content is buffered in memory and
   the file is **moved to `inprogress/`** immediately so it can't be picked twice
   while its (slow) batch is still running. `maxConcurrency=2` keeps within
   Marketo's rate limits.
2. **OAuth** – token from target Marketo.
3. **Bulk Import upload** – `POST /bulk/v1/leads.json?format=csv&lookupField=email&listId=10605`
   as `multipart/form-data` (the chunk CSV as the `file` part). Wrapped in
   `until-successful` so transient connectivity errors are retried.
   Returns a `batchId`. (`lookupField=email` makes the import idempotent — a
   re-run updates instead of duplicating.)
4. **Poll batch** – `GET /bulk/v1/leads/batch/{batchId}.json` until `Complete` or
   `Failed`; capture `numOfRowsFailed`.
5. **Row failures** – if `numOfRowsFailed > 0`, `GET …/{batchId}/failures.json` and
   **append** those rows to `error.csv` (`failureReason=IMPORT_DATA_FAILURE`).
6. **Archive + status** – move the chunk to `processed/` and append a row to
   `status.csv` (`chunk, batchId, status, failedRows, timestamp`).

### Error handling (per chunk, independent)
Each chunk is processed in its own `try`; a failure in one never stops the others.

- **Connectivity failure** (timeout / 5xx / retries exhausted) → chunk moved to
  `reprocess/`, a reason row appended to `reprocess.csv`, status `REPROCESS`.
  To retry, drop the file from `reprocess/` back into `source/`.
- **Data failure** (Marketo rejects the whole request, e.g. bad mapping) → chunk
  rows appended to `error.csv` (`failureReason=IMPORT_REJECTED`), file moved to
  `processed/`, status `DATA_FAILED`.
- **Partial row failures** (batch completes, some rows fail) → only the failed
  rows go to `error.csv`; the chunk still counts as processed.

### Component interaction
```
POST /migrate
  │
  ▼
[Flow A] Source Marketo Bulk Export ──► dedupe.dwl ──┬──► error/error.csv (rejects)
                                                     └──► source/chunk-*.csv (valid, 10 each)
                                                                 │  (file drop)
                                                                 ▼
[Flow B] File Listener ─► inprogress/ ─► Target Marketo Bulk Import ─► poll batch ─► failures
        success ─► processed/ + status.csv
        row fail ─► error.csv
        data fail ─► error.csv + processed/
        conn fail ─► reprocess/ + reprocess.csv
```

---

## Run it

1. Import into Anypoint Studio; **Run As → Mule Application**.
2. Kick off extraction:
   ```
   curl -X POST http://localhost:8081/migrate
   ```
3. Watch `data/source/` fill with chunk files, then `data/processed/` as the
   listener imports them. Check `data/error/error.csv`, `data/reprocess/`, and
   `data/status/status.csv`.

## Notes / hardening for production
- Creds are inline in `config.yaml` for the demo — move to Secure Properties.
- Token refresh if a run exceeds ~1 hour (Marketo token TTL).
- Flow A writes chunks straight into `source/`; for very large volumes write to a
  staging folder and move into `source/` to fully rule out partial-file pickup.
- `error.csv` / `status.csv` are appended with `header=false`; add a one-time
  header row if you want column names in the files.
