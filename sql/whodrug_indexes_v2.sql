-- Apply on existing WHODrug databases that were created with the v1 index set.
-- Idempotent: safe to re-run.
--
-- Locking: CREATE INDEX (non-concurrent) takes a ShareLock on mp. Reads remain
-- allowed; concurrent writes (only the bulk-load script writes to mp) will block
-- until the transaction commits. WHODrug is effectively read-only at runtime, so
-- this is safe to run online without a maintenance window.

BEGIN;

-- Drop unused / superseded indexes (no consumer in ecrf code or downstream tools)
DROP INDEX IF EXISTS idx_mp_drug_name_trgm;
DROP INDEX IF EXISTS idx_mp_country;
DROP INDEX IF EXISTS idx_mp_product_type;
DROP INDEX IF EXISTS idx_sun_substance_name_trgm;

-- Drop legacy single-column indexes now covered as left-prefix of idx_mp_drug_key_name
DROP INDEX IF EXISTS idx_mp_drug_rec_no;
DROP INDEX IF EXISTS idx_mp_drug_rec_no_seq1;

-- Create the new optimized indexes (CREATE INDEX IF NOT EXISTS is idempotent by NAME
-- only — if an index with the same name but a different definition exists, it is left
-- untouched. Manual interventions on the target DB should be audited before running.)
CREATE INDEX IF NOT EXISTS idx_mp_drug_name_lower_pattern
  ON mp (lower(drug_name) text_pattern_ops);

CREATE INDEX IF NOT EXISTS idx_mp_drug_code
  ON mp ((drug_rec_no || seq1 || seq2));

CREATE INDEX IF NOT EXISTS idx_mp_drug_key_name
  ON mp (drug_rec_no, seq1, seq2, lower(drug_name));

-- Active-ingredient search: prefix LIKE on lower(substance_name). The v1 index set
-- had no substance_name index (trigram was dropped above), so the ecrf ingredient
-- branch would seq scan sun without this.
CREATE INDEX IF NOT EXISTS idx_sun_substance_name_lower_pattern
  ON sun (lower(substance_name) text_pattern_ops);

-- Exact NORMALIZED match on drug_name for the medical-coding auto-code path (ecrf
-- findExactCurrentDrug / findExactCurrentDrugBatch). Functional expression not served by any
-- prefix index → without it the auto-code seq scans ~5.6M rows (~6.2s per lookup) on the
-- interactive 1st-save path. Accent maps MUST stay byte-identical to ecrf coding-term-accents.ts
-- (ACCENT_FROM / ACCENT_TO) or the planner will not match this index. Build ~1min on 5.6M rows.
CREATE INDEX IF NOT EXISTS idx_mp_drug_name_normalized
  ON mp (translate(btrim(regexp_replace(lower(drug_name), '\s+', ' ', 'g')),
    'áàâãäåéèêëíìîïóòôõöøúùûüçñýÿÁÀÂÃÄÅÉÈÊËÍÌÎÏÓÒÔÕÖØÚÙÛÜÇÑÝŸ',
    'aaaaaaeeeeiiiioooooouuuucnyyaaaaaaeeeeiiiioooooouuuucnyy'));

COMMIT;

-- Run ANALYZE outside the transaction
ANALYZE mp;
ANALYZE thg;
ANALYZE ing;
ANALYZE sun;
