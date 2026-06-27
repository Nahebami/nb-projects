# Databricks notebook source
# MAGIC %md
# MAGIC # Publisher resolution — three groupings + Perlego ground-truth enrichment
# MAGIC
# MAGIC Per book, side by side:
# MAGIC 1. **`group_variant_name`** — OLD raw name-only algorithm.
# MAGIC 2. **`group_canonical_name`**  — CURRENT signed-off production grouping.
# MAGIC 3. **`group_isbn_name`**      — NEW ISBN-registrant + authority/crosswalk method.
# MAGIC
# MAGIC Plus Perlego's own publisher name (ground truth) and accuracy flags that let
# MAGIC the business see, on the verifiable on-platform slice, that `group_isbn_name`
# MAGIC matches Perlego more often than `group_canonical_name` does.

# COMMAND ----------

# MAGIC %md
# MAGIC ## ▶ Setup — install isbnlib
# MAGIC On serverless: add `isbnlib` in the **Environment side panel** (Add dependency → Apply), then Run All.
# MAGIC On a cluster: run the `%pip` cell on its own first, then run the rest top to bottom.

# COMMAND ----------

# MAGIC %pip install isbnlib

# COMMAND ----------

# Parameters
# Defaults below are generic placeholders for this public portfolio.
# Point them at your own catalog.schema.table values before running.
dbutils.widgets.removeAll()   # clear any stale widget values so the defaults below always apply
dbutils.widgets.text("input_table",     "your_catalog.your_schema.content_acquisition_baseline_model")
dbutils.widgets.text("mapping_table",   "your_catalog.your_schema.publisher_name_mapping")
dbutils.widgets.text("authority_table", "your_catalog.your_schema.publisher_authority")  # ground-truth publisher names
dbutils.widgets.text("output_table",    "your_catalog.your_schema.publisher_dedup_mapping_data")

INPUT_TABLE     = dbutils.widgets.get("input_table")
MAPPING_TABLE   = dbutils.widgets.get("mapping_table").strip()
AUTHORITY_TABLE = dbutils.widgets.get("authority_table").strip()
OUTPUT_TABLE    = dbutils.widgets.get("output_table")

# COMMAND ----------

import re
from collections import Counter, defaultdict
import pandas as pd
import isbnlib

STOPWORDS = {"inc","incorporated","ltd","limited","llc","co","corp","corporation",
    "press","publishing","publishers","pub","books","group","media","company",
    "the","and","of","de","from","order","now","email","pos","submit","use","via","only","do","not"}
PUNCT = re.compile(r"[^\w\s]"); WS = re.compile(r"\s+")

def normalise(name):
    if not isinstance(name, str): return ""
    s = WS.sub(" ", PUNCT.sub(" ", name.lower())).strip()
    return " ".join(t for t in s.split(" ") if t and t not in STOPWORDS)

def tokens(name):
    n = normalise(name); return n.split() if n else []

def contains_seq(a, b):
    if not b or len(b) > len(a): return False
    return any(a[i:i+len(b)] == b for i in range(len(a)-len(b)+1))

# ---- helpers added for the new outputs ----
def clean_isbn(s):
    return re.sub(r"\D", "", str(s)) if s is not None else ""

def is_blank(s):
    return s is None or (isinstance(s, float) and pd.isna(s))

def up(s):                                   # UPPERCASE display label
    return None if is_blank(s) else str(s).strip().upper()

def mkey(s):                                 # normalised key for matching (lower, alnum only)
    return "" if is_blank(s) else re.sub(r"[^a-z0-9]", "", str(s).lower())

def name_match(a, b):                        # conservative ground-truth match
    x, y = mkey(a), mkey(b)
    if not x or not y: return False
    return x == y or x.startswith(y) or y.startswith(x) or x in y or y in x

class DSU:
    def __init__(self, n): self.p = list(range(n))
    def find(self, x):
        while self.p[x] != x: self.p[x] = self.p[self.p[x]]; x = self.p[x]
        return x
    def union(self, a, b): self.p[self.find(a)] = self.find(b)

# imprint -> parent crosswalk (REPLACE with your reviewed imprint sheet)
IMPRINT_TO_PARENT = [
    (re.compile(r"^(PPG-|RHPG-|KDPG-|PYR-|PENGUIN\b)"),               "PENGUIN RANDOM HOUSE"),
    (re.compile(r"MACMILLAN|FARRAR|BEDFORD/SAINT|ST MARTIN|PICADOR"), "MACMILLAN"),
    (re.compile(r"HACHETTE|BASIC BOOKS|LITTLE/ BROWN"),               "HACHETTE BOOK GROUP"),
    (re.compile(r"MOSBY|^ELSEVIER"),                                  "ELSEVIER"),
    (re.compile(r"LIPPINCOTT|WOLTERS KLUWER|^LWW\b"),                 "WOLTERS KLUWER"),
    (re.compile(r"F\.?\s?A\.? DAVIS"),                                "F. A. DAVIS COMPANY"),
]
DISTRIBUTORS = re.compile(r"INGRAM|PUBLISHERS GROUP WEST|HOPKINS FULFILLMENT|ORDER FROM")

def parent_of(label):
    for rx, parent in IMPRINT_TO_PARENT:
        if rx.search(str(label)): return parent
    return None

def registrant(isbn):
    s = clean_isbn(isbn)
    if not isbnlib.is_isbn13(s): return None
    m = isbnlib.mask(s)
    if not m: return None
    p = m.split("-")
    return f"{p[0]}-{p[1]}-{p[2]}" if len(p) >= 4 else None

# OLD method: name-only grouping
ANCHOR_MAX_DOCS = 20
def resolve_name_only(pubs):
    uniq = sorted(set(map(str, pubs)))
    idx  = {p: i for i, p in enumerate(uniq)}
    toks = [tokens(p) for p in uniq]; norms = [normalise(p) for p in uniq]
    freq = Counter()
    for t in toks:
        for tok in set(t): freq[tok] += 1
    anchor = {t for t, c in freq.items() if c <= ANCHOR_MAX_DOCS and len(t) >= 3 and not t.isdigit()}
    dsu = DSU(len(uniq))
    by_norm = defaultdict(list)
    for i, nm in enumerate(norms):
        if nm: by_norm[nm].append(i)
    for ids in by_norm.values():
        for j in ids[1:]: dsu.union(ids[0], j)
    for i in range(len(uniq)):
        for j in range(i+1, len(uniq)):
            ti, tj = toks[i], toks[j]; si, sj = set(ti), set(tj)
            short = si if len(si) <= len(sj) else sj
            if not short: continue
            if contains_seq(ti, tj) or contains_seq(tj, ti):
                if short & anchor: dsu.union(i, j); continue
            ov = si & sj
            if ov and len(ov)/len(short) >= 0.80 and (ov & anchor): dsu.union(i, j)
    groups = defaultdict(list)
    for p, i in idx.items(): groups[dsu.find(i)].append(p)
    canon = {}
    for members in groups.values():
        rep = max(members, key=len)
        for m in members: canon[m] = rep
    return canon

# NEW method: ISBN registrant + authority/crosswalk naming.
# pdf must have columns: 'isbn13', 'bmg_publisher'. Returns per-index entity + auth_used.
def resolve_isbn(pdf, authority):
    pdf = pdf.copy()
    pdf["reg"] = pdf["isbn13"].map(registrant)
    entity = {}; auth_used = {}
    # no usable ISBN -> fall back to the raw publisher name (NO "[NO-ISBN]" prefix)
    for i, r in pdf[pdf["reg"].isna()].iterrows():
        entity[i] = str(r["bmg_publisher"]); auth_used[i] = False
    valid = pdf[pdf["reg"].notna()]
    auth_name, rep_label = {}, {}
    for reg, g in valid.groupby("reg"):
        perlego = [authority[x] for x in g["isbn13"] if x in authority and pd.notna(authority[x])]
        if perlego: auth_name[reg] = Counter(perlego).most_common(1)[0][0]
        labels = g["bmg_publisher"].astype(str).tolist()
        pool = [l for l in labels if not DISTRIBUTORS.search(l)] or labels
        rep_label[reg] = Counter(pool).most_common(1)[0][0]
    for i, r in valid.iterrows():
        reg = r["reg"]
        if reg in auth_name:                          # Perlego's own label names the cluster
            name = auth_name[reg]; entity[i] = parent_of(name) or name; auth_used[i] = True
        else:
            name = rep_label[reg]
            entity[i] = parent_of(name) or parent_of(str(r["bmg_publisher"])) or name
            auth_used[i] = False
    return entity, auth_used

# COMMAND ----------

# read input
sdf = spark.table(INPUT_TABLE)
have = set(sdf.columns)
assert {"isbn_id","bmg_publisher"} <= have, "input needs at least isbn_id and bmg_publisher"
cols = [c for c in ["isbn_id","bmg_publisher","bmg_title"] if c in have]
pdf = sdf.select(*cols).toPandas()
if "bmg_title" not in pdf.columns: pdf["bmg_title"] = None
pdf["isbn13"] = pdf["isbn_id"].map(clean_isbn)
print(f"{len(pdf):,} books read from {INPUT_TABLE}")

# current reviewed mapping: Variant Name -> Canonical Name
reviewed = {}
if MAPPING_TABLE:
    mdf = spark.table(MAPPING_TABLE).select("`Variant Name`","`Canonical Name`").toPandas()
    reviewed = dict(zip(mdf["Variant Name"].astype(str), mdf["Canonical Name"]))
    print(f"{len(reviewed):,} variant->canonical rows read from {MAPPING_TABLE}")

# Perlego authority (ground truth): cleaned isbn -> Perlego publisher name
authority = {}
if AUTHORITY_TABLE:
    adf = spark.table(AUTHORITY_TABLE).select("isbn_id","perlego_publisher").toPandas()
    authority = {clean_isbn(k): v for k, v in zip(adf["isbn_id"], adf["perlego_publisher"])}
    print(f"{len(authority):,} Perlego authority labels read from {AUTHORITY_TABLE}")

# COMMAND ----------

# ---- run all three methods ----
name_canon = resolve_name_only(pdf["bmg_publisher"].tolist())
pdf["group_variant_name_raw"] = pdf["bmg_publisher"].astype(str).map(name_canon)
pdf["group_canonical_name_raw"]  = pdf["bmg_publisher"].astype(str).map(
    lambda p: reviewed.get(p, p) if reviewed else None)

new_entity, auth_used = resolve_isbn(pdf[["isbn13","bmg_publisher"]], authority)
pdf["registrant"]     = pdf["isbn13"].map(registrant)
pdf["isbn_resolved"]  = pdf["registrant"].notna()                       # (3) flag: name came from ISBN vs raw fallback
pdf["group_isbn_name_raw"] = pdf.index.map(lambda i: new_entity[i])
pdf["authority_used"] = pdf.index.map(lambda i: bool(auth_used[i]))

# ---- (2) Perlego ground-truth name + on-platform flag ----
pdf["perlego_publisher_raw"] = pdf["isbn13"].map(lambda x: authority.get(x))
pdf["on_perlego"]            = pdf["isbn13"].map(lambda x: x in authority)

# ---- (1) UPPERCASE display columns + lowercase/normalised keys ----
for col in ["group_variant_name","group_canonical_name","group_isbn_name","perlego_publisher"]:
    pdf[col]          = pdf[col+"_raw"].map(up)
    pdf[col+"_norm"]  = pdf[col+"_raw"].map(mkey)

# ---- agreement + (5) accuracy enrichment vs Perlego ground truth ----
pdf["canonical_vs_isbn_agree"]   = pdf["group_isbn_name_norm"] == pdf["group_canonical_name_norm"]
pdf["isbn_matches_perlego"]     = [name_match(a,b) if op else False
    for a,b,op in zip(pdf["group_isbn_name_raw"], pdf["perlego_publisher_raw"], pdf["on_perlego"])]
pdf["canonical_matches_perlego"] = [name_match(a,b) if op else False
    for a,b,op in zip(pdf["group_canonical_name_raw"], pdf["perlego_publisher_raw"], pdf["on_perlego"])]

def outcome(op, im, rm):
    if not op:        return "not_verifiable"      # book not on Perlego -> no ground truth
    if im and rm:     return "both_match"
    if im:            return "isbn_only_match"      # NEW wins
    if rm:            return "canonical_only_match"  # CURRENT wins
    return "neither_match"
pdf["accuracy_outcome"] = [outcome(o,i,r) for o,i,r in
    zip(pdf["on_perlego"], pdf["isbn_matches_perlego"], pdf["canonical_matches_perlego"])]

# ---- single best-available name, by trust priority ----
# Perlego name > ISBN logic name (only if ISBN resolved) > Canonical name (only if
# the variant actually matched the reviewed mapping) > BMG raw name. The "only if"
# guards keep publisher_best_source honest — an unresolved ISBN or unmatched variant
# just echoes the raw label, so it must not claim a stronger source.
canon_hit = (pdf["bmg_publisher"].astype(str).map(lambda p: p in reviewed)
             if reviewed else pd.Series(False, index=pdf.index))
best_name, best_src = [], []
for op, pp, ir, gi, ch, gc, raw in zip(
        pdf["on_perlego"], pdf["perlego_publisher_raw"], pdf["isbn_resolved"],
        pdf["group_isbn_name_raw"], canon_hit, pdf["group_canonical_name_raw"], pdf["bmg_publisher"]):
    if op and not is_blank(pp):       best_name.append(up(pp));  best_src.append("Perlego name")
    elif ir:                          best_name.append(up(gi));  best_src.append("ISBN logic name")
    elif ch and not is_blank(gc):     best_name.append(up(gc));  best_src.append("Canonical name")
    else:                             best_name.append(up(raw)); best_src.append("BMG raw name")
pdf["publisher_best"]        = best_name
pdf["publisher_best_source"] = best_src

review = pdf.rename(columns={"bmg_publisher":"bmg_publisher_raw"})[[
    "isbn_id","bmg_publisher_raw","bmg_title","registrant","isbn_resolved",
    "group_variant_name","group_canonical_name","group_isbn_name",
    "group_variant_name_norm","group_canonical_name_norm","group_isbn_name_norm",
    "perlego_publisher","perlego_publisher_norm","on_perlego",
    "authority_used","canonical_vs_isbn_agree",
    "isbn_matches_perlego","canonical_matches_perlego","accuracy_outcome",
    "publisher_best","publisher_best_source",
]]
review["isbn_id"] = review["isbn_id"].astype(str)

# COMMAND ----------

# ---- write output ----
from pyspark.sql.types import StructType, StructField, StringType, BooleanType
S = StringType(); B = BooleanType()
OUTPUT_SCHEMA = StructType([
    StructField("isbn_id", S, True),
    StructField("bmg_publisher_raw", S, True),
    StructField("bmg_title", S, True),
    StructField("registrant", S, True),
    StructField("isbn_resolved", B, True),            # TRUE = group_isbn_name derived from ISBN; FALSE = raw-name fallback
    StructField("group_variant_name", S, True),          # OLD (UPPER)
    StructField("group_canonical_name", S, True),           # CURRENT (UPPER)
    StructField("group_isbn_name", S, True),               # NEW (UPPER)
    StructField("group_variant_name_norm", S, True),     # lowercase alnum key for exact matching
    StructField("group_canonical_name_norm", S, True),
    StructField("group_isbn_name_norm", S, True),
    StructField("perlego_publisher", S, True),         # Perlego ground-truth name (UPPER), null if off-platform
    StructField("perlego_publisher_norm", S, True),
    StructField("on_perlego", B, True),                # TRUE = ISBN exists in Perlego catalogue (verifiable)
    StructField("authority_used", B, True),            # TRUE = cluster named from Perlego's label
    StructField("canonical_vs_isbn_agree", B, True),    # TRUE = CURRENT and NEW agree
    StructField("isbn_matches_perlego", B, True),      # accuracy: NEW vs ground truth (on-platform only)
    StructField("canonical_matches_perlego", B, True),  # accuracy: CURRENT vs ground truth (on-platform only)
    StructField("accuracy_outcome", S, True),          # both/isbn_only/canonical_only/neither/not_verifiable
    StructField("publisher_best", S, True),            # single best-available name (UPPER), by trust priority
    StructField("publisher_best_source", S, True),     # 'Perlego name' | 'ISBN logic name' | 'Canonical name' | 'BMG raw name'
])
out_sdf = spark.createDataFrame(review.astype(object).where(pd.notna(review), None), schema=OUTPUT_SCHEMA)
(out_sdf.write.mode("overwrite").option("overwriteSchema","true").saveAsTable(OUTPUT_TABLE))
print(f"Wrote {out_sdf.count():,} rows to {OUTPUT_TABLE}")

# COMMAND ----------

# MAGIC %md
# MAGIC ### Column dictionary
# MAGIC | column | meaning |
# MAGIC |---|---|
# MAGIC | `group_variant_name` / `group_canonical_name` / `group_isbn_name` | publisher under OLD / CURRENT / NEW method (UPPERCASE) |
# MAGIC | `*_norm` | lowercase-alphanumeric key of each, for exact-match comparisons |
# MAGIC | `isbn_resolved` | TRUE = `group_isbn_name` came from the ISBN; FALSE = no ISBN, fell back to the raw name |
# MAGIC | `perlego_publisher` | Perlego's own publisher name = **ground truth** (null if book is off-platform) |
# MAGIC | `on_perlego` | TRUE = ISBN is in Perlego's catalogue, so the row is **verifiable** |
# MAGIC | `authority_used` | TRUE = the cluster was named using Perlego's label (high confidence) |
# MAGIC | `canonical_vs_isbn_agree` | TRUE = CURRENT and NEW put the book under the same publisher (not a correctness flag) |
# MAGIC | `isbn_matches_perlego` / `canonical_matches_perlego` | on the verifiable slice, does NEW / CURRENT match Perlego? |
# MAGIC | `accuracy_outcome` | per-book verdict: `isbn_only_match` = NEW right & CURRENT wrong, etc. |
# MAGIC | `publisher_best` | **single best-available name** to join on, by trust priority |
# MAGIC | `publisher_best_source` | which source filled it: `Perlego name` > `ISBN logic name` > `Canonical name` > `BMG raw name` |

# COMMAND ----------

# ====== BUSINESS HEADLINE: accuracy on the verifiable (on-Perlego) slice ======
spark.sql(f"""
  SELECT
    COUNT(*)                                                                       AS books_on_perlego,
    ROUND(100.0*SUM(CASE WHEN isbn_matches_perlego     THEN 1 ELSE 0 END)/COUNT(*),1) AS new_isbn_match_pct,
    ROUND(100.0*SUM(CASE WHEN canonical_matches_perlego THEN 1 ELSE 0 END)/COUNT(*),1) AS current_reviewed_match_pct
  FROM {OUTPUT_TABLE}
  WHERE on_perlego
""").display()

# Per-book verdict breakdown — isbn_only_match >> reviewed_only_match means NEW is more accurate
spark.sql(f"""
  SELECT accuracy_outcome, COUNT(*) AS books,
         ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),1) AS pct
  FROM {OUTPUT_TABLE}
  WHERE on_perlego
  GROUP BY accuracy_outcome ORDER BY books DESC
""").display()

# COMMAND ----------

# Distinct publisher counts per method (consolidation view)
spark.sql(f"""
  SELECT
    COUNT(DISTINCT group_variant_name) AS publishers_variant,
    COUNT(DISTINCT group_canonical_name)  AS publishers_canonical,
    COUNT(DISTINCT CASE WHEN isbn_resolved THEN group_isbn_name END) AS publishers_isbn,
    COUNT(DISTINCT publisher_best) AS publishers_best
  FROM {OUTPUT_TABLE}
""").display()

# Where publisher_best gets its name from — coverage of each source
spark.sql(f"""
  SELECT publisher_best_source, COUNT(*) AS books,
         ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),1) AS pct
  FROM {OUTPUT_TABLE}
  GROUP BY publisher_best_source ORDER BY books DESC
""").display()

# Review queue: where CURRENT and NEW disagree (ISBN-resolved only), biggest first
spark.sql(f"""
  SELECT group_canonical_name, group_isbn_name, COUNT(*) AS books,
         MAX(authority_used) AS any_authority,
         MAX(on_perlego)     AS any_on_perlego
  FROM {OUTPUT_TABLE}
  WHERE NOT canonical_vs_isbn_agree AND isbn_resolved
  GROUP BY group_canonical_name, group_isbn_name
  ORDER BY books DESC
""").display()
