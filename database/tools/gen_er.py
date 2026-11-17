#!/usr/bin/env python3
"""Builds docs/er_diagram.mmd from the live gamevault_db schema (information_schema)."""
import subprocess, sys, collections
def q(sql):
    out = subprocess.run(["mysql", "-uroot", "-N", "-B", "-e", sql], capture_output=True, text=True, check=True).stdout.rstrip("\n")
    return [l.split("\t") for l in out.splitlines()]
S = "gamevault_db"
cols = q(f"select c.table_name,c.column_name,c.data_type,c.column_key from information_schema.columns c join information_schema.tables t using (table_schema,table_name) where table_schema='{S}' and t.table_type='BASE TABLE' order by c.table_name,c.ordinal_position")
fks = q(f"select k.table_name,k.referenced_table_name,k.constraint_name,group_concat(k.column_name order by k.ordinal_position) from information_schema.key_column_usage k where k.table_schema='{S}' and k.referenced_table_name is not null group by k.table_name,k.referenced_table_name,k.constraint_name")
fkcols = {(t, c) for t, _, _, cs in fks for c in cs.split(",")}
uniq = q(f"select table_name,column_name from information_schema.statistics where table_schema='{S}' and non_unique=0 and index_name<>'PRIMARY'")
uq = {(t, c) for t, c in uniq}
pk_count = collections.Counter(t for t, _, _, k in cols if k == "PRI")
junction = {t for t, n in pk_count.items() if n >= 2}
ty = {"int":"int","bigint":"bigint","tinyint":"tinyint","smallint":"smallint","varchar":"varchar","text":"text","date":"date","datetime":"datetime","timestamp":"timestamp","decimal":"decimal","json":"json","char":"char","enum":"enum","longtext":"text"}
lines = ["erDiagram"]
byt = collections.OrderedDict()
for t, c, d, k in cols: byt.setdefault(t, []).append((c, d, k))
for t, cs in byt.items():
    lines.append(f"    {t} {{")
    for c, d, k in cs:
        keys = []
        if k == "PRI": keys.append("PK")
        if (t, c) in fkcols: keys.append("FK")
        if (t, c) in uq and k != "PRI": keys.append("UK")
        lines.append(f"        {ty.get(d, d)} {c} {','.join(keys)}".rstrip())
    lines.append("    }")
for t, ref, name, cs in sorted(fks):
    cl = cs.split(",")
    one_to_one = (t in junction and len(cl) == 1 and False)
    label = "_".join(cl)[:40]
    # parent ||--o{ child : the child holds the FK
    lines.append(f'    {ref} ||--o{{ {t} : "{label}"')
open("docs/er_diagram.mmd", "w").write("\n".join(lines) + "\n")
print(len(byt), "tables,", len(fks), "relationships")
