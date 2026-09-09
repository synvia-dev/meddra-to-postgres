#!/bin/bash
#############################################################################
#
set -e
#
T0=$(date +%s)
#
cwd=$(pwd)
#
# PostgreSQL connection parameters for Docker
export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5433}"
export PGUSER="${PGUSER:-meddict}"
export PGPASSWORD="${PGPASSWORD:-meddict}"
#
if [ ! -f ${cwd}/LATEST_RELEASE.txt ]; then
  printf "ERROR: not found: ${cwd}/LATEST_RELEASE.txt\n"
  exit
fi
DBVERSION=$(tr -d '[:space:]' <${cwd}/LATEST_RELEASE.txt)
printf "From ${cwd}/LATEST_RELEASE.txt: ${DBVERSION}\n"
#
# MedDRA ships one distribution per translation, all sharing the same term codes.
# The consumer (eCRF) resolves the database per study as `meddra_<version>[_<lang>]`,
# where the UNSUFFIXED name is the legacy Portuguese load. So set MEDDRA_LANG to the
# language tag of the distribution in data/MedAscii — empty (default) builds the
# Portuguese database, `en` builds meddra_<version>_en.
#
# EVERY new MedDRA version has to be loaded once per language below: studies pick the
# language individually and the eCRF refuses to fall back to another one, so a version
# present in only one language breaks Medical Coding for the studies on the other.
#
# Lowercased because Postgres folds unquoted identifiers: `MEDDRA_LANG=EN` would miss
# the `meddra_<version>_en` row in the existence check below and then have its
# DROP/CREATE folded onto that very database.
MEDDRA_LANG="$(printf '%s' "${MEDDRA_LANG:-}" | tr '[:upper:]' '[:lower:]')"
#
# Suffixes the consumer knows how to resolve (`medicalCodingDictionaryLanguages`, in
# packages/db-schemas/src/schemas/core/medical-coding-config.ts). `pt` is deliberately
# absent: it maps to the UNSUFFIXED name. Anything outside this list builds a database
# no study can ever read, and the load only fails much later, at query time.
MEDDRA_LANGS="en"
if [ "$MEDDRA_LANG" = "pt" ]; then
  printf "ERROR: Portuguese uses the UNSUFFIXED database name — re-run without MEDDRA_LANG.\n"
  exit 1
fi
LANGSUFFIX=""
if [ -n "$MEDDRA_LANG" ]; then
  case " ${MEDDRA_LANGS} " in
  *" ${MEDDRA_LANG} "*) ;;
  *)
    printf "ERROR: unsupported MEDDRA_LANG '${MEDDRA_LANG}' (supported: ${MEDDRA_LANGS}).\n"
    printf "       The eCRF only resolves the suffixes above, so any other one builds a\n"
    printf "       database no study reads. Add the language to the consumer enum first.\n"
    exit 1
    ;;
  esac
  LANGSUFFIX="_${MEDDRA_LANG}"
fi
DBNAME="meddra_$(echo $DBVERSION | sed 's/\.//g')${LANGSUFFIX}"
printf "TARGET DATABASE: ${DBNAME} (${PGHOST}:${PGPORT}, lang='${MEDDRA_LANG:-pt (unsuffixed)}')\n"
#
# The load below is destructive (DROP DATABASE). Refuse to clobber a database that
# already exists unless the caller opts in: on a shared server a forgotten
# MEDDRA_LANG resolves to the unsuffixed name and would wipe the Portuguese
# `meddra_<version>` that studies are reading right now.
DB_EXISTS=$(psql -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname = '${DBNAME}'")
if [ -n "$DB_EXISTS" ] && [ "${MEDDRA_DB_OVERWRITE:-}" != "1" ]; then
  printf "ERROR: database '${DBNAME}' already exists on ${PGHOST}:${PGPORT}.\n"
  printf "       Check MEDDRA_LANG and LATEST_RELEASE.txt. To DROP and rebuild it\n"
  printf "       anyway, re-run with MEDDRA_DB_OVERWRITE=1.\n"
  exit 1
fi
#
DATADIR="${cwd}/data"
#
if [ ! -e "$DATADIR" ]; then
  mkdir $DATADIR
fi
#
DBDIR=$(
  # cd $HOME/../data/MedDRA/${DBVERSION}
  cd data
  pwd
)
#
if [ ! -e "${DBDIR}" ]; then
  printf "ERROR: DBDIR not found: ${DBDIR}\n"
  exit 1
fi
#
# The distribution declares its own version and language in meddra_release.asc, as
# `<version>$<language>$$$$`. Assert both against what the caller declared, because
# nothing else does: the DROP guard stops us from clobbering the WRONG database, but a
# stale data/MedAscii still builds the RIGHT database with the wrong content — English
# `.asc` files loaded as `meddra_290`, or Portuguese ones as `meddra_290_en`. That fails
# nowhere; it surfaces weeks later as a coder who cannot find their own terms.
# Normalization: strip CR/LF (the pt distribution is CRLF, the en one has no trailing
# newline at all) and outer spaces, but NOT inner ones — the language is a phrase
# ("Brazilian Portuguese").
RELEASE_ASC="${DBDIR}/MedAscii/meddra_release.asc"
if [ ! -f "$RELEASE_ASC" ]; then
  printf "WARNING: ${RELEASE_ASC} not found — skipping version/language assertion.\n"
else
  asc_field() { cut -d'$' -f"$1" "$RELEASE_ASC" | head -1 | tr -d '\r\n' | sed -E 's/^ +| +$//g'; }
  ASC_VERSION=$(asc_field 1)
  ASC_LANG=$(asc_field 2)
  # Only `en` and the unsuffixed default reach this point (see the allowlist above).
  if [ "$MEDDRA_LANG" = "en" ]; then
    EXPECTED_ASC_LANG="English"
  else
    EXPECTED_ASC_LANG="Brazilian Portuguese"
  fi
  if [ "$ASC_VERSION" != "$DBVERSION" ]; then
    printf "ERROR: data/MedAscii is MedDRA ${ASC_VERSION}, but LATEST_RELEASE.txt says ${DBVERSION}.\n"
    printf "       Loading it would populate '${DBNAME}' with ${ASC_VERSION} terms. Fix one of the two.\n"
    exit 1
  fi
  if [ "$ASC_LANG" != "$EXPECTED_ASC_LANG" ]; then
    printf "ERROR: data/MedAscii is the '${ASC_LANG}' distribution, but the target is\n"
    printf "       '${DBNAME}' (MEDDRA_LANG='${MEDDRA_LANG:-<unset>}', expects '${EXPECTED_ASC_LANG}').\n"
    printf "       Swap the .asc files or fix MEDDRA_LANG. If MedDRA renamed the language,\n"
    printf "       update the mapping in this script.\n"
    exit 1
  fi
  printf "DISTRIBUTION: MedDRA ${ASC_VERSION} ${ASC_LANG} — matches target.\n"
fi
#
printf "CONVERTING RAW FILES TO TSVS.\n"
${cwd}/python/meddra_utils.py convert_soc --i ${DBDIR}/MedAscii/soc.asc --o $DATADIR/meddra_soc.tsv
${cwd}/python/meddra_utils.py convert_hlt --i ${DBDIR}/MedAscii/hlt.asc --o $DATADIR/meddra_hlt.tsv
${cwd}/python/meddra_utils.py convert_hlgt --i ${DBDIR}/MedAscii/hlgt.asc --o $DATADIR/meddra_hlgt.tsv
${cwd}/python/meddra_utils.py convert_pt --i ${DBDIR}/MedAscii/pt.asc --o $DATADIR/meddra_pt.tsv
${cwd}/python/meddra_utils.py convert_llt --i ${DBDIR}/MedAscii/llt.asc --o $DATADIR/meddra_llt.tsv
${cwd}/python/meddra_utils.py convert_llt2pt --i ${DBDIR}/MedAscii/llt.asc --o $DATADIR/meddra_llt2pt.tsv
${cwd}/python/meddra_utils.py convert_soc2hlgt --i ${DBDIR}/MedAscii/soc_hlgt.asc --o $DATADIR/meddra_soc2hlgt.tsv
${cwd}/python/meddra_utils.py convert_hlgt2hlt --i ${DBDIR}/MedAscii/hlgt_hlt.asc --o $DATADIR/meddra_hlgt2hlt.tsv
${cwd}/python/meddra_utils.py convert_hlt2pt --i ${DBDIR}/MedAscii/hlt_pt.asc --o $DATADIR/meddra_hlt2pt.tsv
${cwd}/python/meddra_utils.py convert_soc2intl --i ${DBDIR}/MedAscii/intl_ord.asc --o $DATADIR/meddra_intl.tsv
${cwd}/python/meddra_utils.py convert_smq_list --i ${DBDIR}/MedAscii/smq_list.asc --o $DATADIR/meddra_smq_list.tsv
${cwd}/python/meddra_utils.py convert_smq_content --i ${DBDIR}/MedAscii/smq_content.asc --o $DATADIR/meddra_smq_content.tsv
#
#
tsvfiles="\
$DATADIR/meddra_soc.tsv \
$DATADIR/meddra_hlgt.tsv \
$DATADIR/meddra_soc2hlgt.tsv \
$DATADIR/meddra_hlt.tsv \
$DATADIR/meddra_hlgt2hlt.tsv \
$DATADIR/meddra_pt.tsv \
$DATADIR/meddra_hlt2pt.tsv \
$DATADIR/meddra_llt.tsv \
$DATADIR/meddra_llt2pt.tsv \
$DATADIR/meddra_intl.tsv \
$DATADIR/meddra_smq_list.tsv \
$DATADIR/meddra_smq_content.tsv \
"
#
# -d postgres: a bare `psql -c` connects to a database named after PGUSER, which
# need not exist on the target server (the prod dictionary host has no `meddict`).
# Quoted identifier: keeps the DDL acting on the exact name the existence check above
# looked up in pg_database, instead of on whatever Postgres folds it to.
psql -d postgres -c "DROP DATABASE IF EXISTS \"$DBNAME\""
psql -d postgres -c "CREATE DATABASE \"$DBNAME\""
#
psql -d "$DBNAME" -c "COMMENT ON DATABASE \"$DBNAME\" IS 'MedDRA: Medical Dictionary for Regulatory Activities (v${DBVERSION}${MEDDRA_LANG:+, ${MEDDRA_LANG}})'"
#
i_table="0"
for tsvfile in $tsvfiles; do
  i_table=$(($i + 1))
  n_lines=$(cat $tsvfile | wc -l)
  tname=$(echo $tsvfile | perl -pe 's/^.*meddra_(\S+)\.tsv/$1/;')
  printf "${i_table}. CREATING AND LOADING TABLE: ${tname} FROM INPUT FILE: ${tsvfile} (${n_lines} lines)\n"
  #
  python3 -m BioClients.util.pandas.Csv2Sql \
    create --fixtags --nullify --maxchar 2000 \
    --i $tsvfile --tsv --tablename "$tname" |
    psql -d $DBNAME
  #
  python3 -m BioClients.util.pandas.Csv2Sql \
    insert --fixtags --nullify --maxchar 2000 \
    --i $tsvfile --tsv --tablename "$tname" |
    psql -q -d $DBNAME
  #
done
printf "TABLES CREATED AND LOADED: ${i_table}\n"
#
#psql -d $DBNAME -c "UPDATE soc SET text = NULL WHERE text = ''";
###
psql -d $DBNAME -c "COMMENT ON TABLE soc IS 'MedDRA: System Organ Class (SOC)'"
psql -d $DBNAME -c "COMMENT ON TABLE hlt IS 'MedDRA: High Level Term (HLT)'"
psql -d $DBNAME -c "COMMENT ON TABLE hlgt IS 'MedDRA: High Level Group Term (HLGT)'"
psql -d $DBNAME -c "COMMENT ON TABLE llt IS 'MedDRA: Low Level Term (LLT)'"
psql -d $DBNAME -c "COMMENT ON TABLE pt IS 'MedDRA: Preferred Term (PT)'"
#
#
###
# How to dump and restore:
# pg_dump --no-privileges -Fc -d ${DBNAME} >${DBNAME}.pgdump
# createdb ${DBNAME} ; pg_restore -e -O -x -d ${DBNAME} ${DBNAME}.pgdump
###
printf "Elapsed: %ds\n" "$(($(date +%s) - $T0))"
#
