-- WHODrug Global C3 Indexes (v2 — optimized for prefix-based lookup)
-- Created AFTER data load for better performance
--
-- Drug name lookup is prefix-anchored case-insensitive (LIKE 'term%' on lower(drug_name)).
-- Drug code lookup is exact match on drug_rec_no || seq1 || seq2.
-- Substring/trigram lookup is intentionally NOT supported on the hot path.

-- MP: prefix LIKE on lower(drug_name)
CREATE INDEX idx_mp_drug_name_lower_pattern
  ON mp (lower(drug_name) text_pattern_ops);

-- MP: exact match on the 11-char WHODrug code
CREATE INDEX idx_mp_drug_code
  ON mp ((drug_rec_no || seq1 || seq2));

-- MP: covers DISTINCT ON (drug_rec_no, seq1, seq2) ORDER BY (...) and any
-- left-prefix lookup on drug_rec_no / drug_rec_no+seq1. Replaces the standalone
-- idx_mp_drug_rec_no and idx_mp_drug_rec_no_seq1 indexes (redundant left prefix).
CREATE INDEX idx_mp_drug_key_name
  ON mp (drug_rec_no, seq1, seq2, lower(drug_name));

-- THG: join with mp and atc
CREATE INDEX idx_thg_record_id ON thg(record_id);
CREATE INDEX idx_thg_atc_code ON thg(atc_code);

-- ING: join with mp and sun
CREATE INDEX idx_ing_record_id ON ing(record_id);
CREATE INDEX idx_ing_substance_id ON ing(substance_id);

-- SUN: cas_number (lateral lookups)
CREATE INDEX idx_sun_cas_number ON sun(cas_number);

-- Refresh planner statistics after a full load
ANALYZE mp;
ANALYZE thg;
ANALYZE ing;
ANALYZE sun;
