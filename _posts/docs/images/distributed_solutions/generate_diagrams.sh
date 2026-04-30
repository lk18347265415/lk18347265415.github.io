#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

render() {
    local name=$1
    local dot_file="${ROOT_DIR}/${name}.dot"
    local png_file="${ROOT_DIR}/${name}.png"

    cat >"${dot_file}"
    dot -Tpng "${dot_file}" -o "${png_file}"
}

render "native_assembly_framework" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=LR, labelloc=t, fontsize=18, pad=0.25, nodesep=0.5, ranksep=1.0, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  app [label="Application / Router", fillcolor="#FFF4D6", color="#C08400"];
  shard1 [label="PostgreSQL shard A", fillcolor="#D8F3DC", color="#2D6A4F"];
  shard2 [label="PostgreSQL shard B", fillcolor="#D8F3DC", color="#2D6A4F"];
  shard3 [label="PostgreSQL shard C", fillcolor="#D8F3DC", color="#2D6A4F"];
  agg [label="FDW / query aggregation node", fillcolor="#F1E7FF", color="#7B2CBF"];
  repl [label="Logical replication /\nETL / CDC", fillcolor="#EAF2FF"];

  app -> shard1 [label="route by tenant / key"];
  app -> shard2 [label="route by tenant / key"];
  app -> shard3 [label="route by tenant / key"];
  agg -> shard1 [label="postgres_fdw"];
  agg -> shard2 [label="postgres_fdw"];
  agg -> shard3 [label="postgres_fdw"];
  shard1 -> repl [style=dashed];
  shard2 -> repl [style=dashed];
  shard3 -> repl [style=dashed];
}
DOT

render "native_assembly_principle" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=TB, labelloc=t, fontsize=18, pad=0.25, nodesep=0.45, ranksep=0.8, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  shard [label="Application decides\nwhich shard owns a row"];
  write [label="Write goes to one PostgreSQL\ninstance only", fillcolor="#D8F3DC", color="#2D6A4F"];
  fanout [label="Cross-shard query uses\nFDW / app fan-out", fillcolor="#FFF4D6", color="#C08400"];
  sync [label="Data movement uses logical\nreplication or ETL jobs"];
  txn [label="Distributed transaction and\nglobal constraint are handled\nby application or middleware", fillcolor="#FDE2E4", color="#B23A48"];

  shard -> write -> fanout -> sync -> txn;
}
DOT

render "citus_framework" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=LR, labelloc=t, fontsize=18, pad=0.25, nodesep=0.5, ranksep=1.0, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  app [label="Application / BI / SQL client", fillcolor="#FFF4D6", color="#C08400"];
  coord [label="Citus coordinator", fillcolor="#F1E7FF", color="#7B2CBF"];
  meta [label="Shard metadata", shape=cylinder, fillcolor="#F1E7FF", color="#7B2CBF"];
  worker1 [label="Worker node 1\nshards", fillcolor="#D8F3DC", color="#2D6A4F"];
  worker2 [label="Worker node 2\nshards", fillcolor="#D8F3DC", color="#2D6A4F"];
  worker3 [label="Worker node 3\nshards", fillcolor="#D8F3DC", color="#2D6A4F"];
  ref [label="Reference tables", fillcolor="#FFF4D6", color="#C08400"];

  app -> coord;
  coord -> meta [label="lookup"];
  coord -> worker1 [label="route query"];
  coord -> worker2 [label="route query"];
  coord -> worker3 [label="route query"];
  ref -> worker1 [style=dashed];
  ref -> worker2 [style=dashed];
  ref -> worker3 [style=dashed];
}
DOT

render "citus_principle" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=TB, labelloc=t, fontsize=18, pad=0.25, nodesep=0.45, ranksep=0.8, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  key [label="Choose distribution key\nsuch as tenant_id"];
  shard [label="Coordinator maps row/query\nto target shard"];
  parallel [label="Workers execute shard-local\nqueries in parallel", fillcolor="#D8F3DC", color="#2D6A4F"];
  merge [label="Coordinator merges partial\nresults and returns output", fillcolor="#FFF4D6", color="#C08400"];
  limit [label="Cross-shard join, transaction,\nand unique constraint support\ndepends on table model", fillcolor="#FDE2E4", color="#B23A48"];

  key -> shard -> parallel -> merge -> limit;
}
DOT

render "xc_xl_framework" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=LR, labelloc=t, fontsize=18, pad=0.25, nodesep=0.5, ranksep=1.0, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  app [label="Application / SQL client", fillcolor="#FFF4D6", color="#C08400"];
  coord1 [label="Coordinator 1", fillcolor="#F1E7FF", color="#7B2CBF"];
  coord2 [label="Coordinator 2", fillcolor="#F1E7FF", color="#7B2CBF"];
  gtm [label="Global transaction manager\nor equivalent metadata", fillcolor="#FDE2E4", color="#B23A48"];
  dn1 [label="Data node 1", fillcolor="#D8F3DC", color="#2D6A4F"];
  dn2 [label="Data node 2", fillcolor="#D8F3DC", color="#2D6A4F"];
  dn3 [label="Data node 3", fillcolor="#D8F3DC", color="#2D6A4F"];

  app -> coord1;
  app -> coord2 [style=dashed];
  coord1 -> gtm [label="xid / snapshot"];
  coord2 -> gtm [label="xid / snapshot"];
  coord1 -> dn1 [label="plan / execute"];
  coord1 -> dn2 [label="plan / execute"];
  coord2 -> dn2 [label="plan / execute"];
  coord2 -> dn3 [label="plan / execute"];
}
DOT

render "xc_xl_principle" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=TB, labelloc=t, fontsize=18, pad=0.25, nodesep=0.45, ranksep=0.8, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  parse [label="Coordinator parses SQL and\nbuilds distributed plan"];
  xid [label="Global xid / snapshot is\nassigned centrally", fillcolor="#FDE2E4", color="#B23A48"];
  exec [label="Each data node executes its\nlocal fragment", fillcolor="#D8F3DC", color="#2D6A4F"];
  commit [label="Coordinator drives two-phase\nor coordinated commit"];
  result [label="Coordinator merges rows and\nreturns a transparent result", fillcolor="#FFF4D6", color="#C08400"];

  parse -> xid -> exec -> commit -> result;
}
DOT

render "compatible_db_framework" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=LR, labelloc=t, fontsize=18, pad=0.25, nodesep=0.5, ranksep=1.0, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  app [label="PostgreSQL protocol client", fillcolor="#FFF4D6", color="#C08400"];
  sql [label="PG-compatible SQL layer", fillcolor="#F1E7FF", color="#7B2CBF"];
  raft [label="Distributed consensus /\nmetadata layer", fillcolor="#FDE2E4", color="#B23A48"];
  store1 [label="Replica group A\nstorage nodes", fillcolor="#D8F3DC", color="#2D6A4F"];
  store2 [label="Replica group B\nstorage nodes", fillcolor="#D8F3DC", color="#2D6A4F"];
  store3 [label="Replica group C\nstorage nodes", fillcolor="#D8F3DC", color="#2D6A4F"];

  app -> sql;
  sql -> raft [label="metadata / txn"];
  sql -> store1 [label="read / write"];
  sql -> store2 [label="read / write"];
  sql -> store3 [label="read / write"];
}
DOT

render "compatible_db_principle" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=TB, labelloc=t, fontsize=18, pad=0.25, nodesep=0.45, ranksep=0.8, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  proto [label="Client speaks PostgreSQL\nwire protocol"];
  plan [label="SQL layer parses query and\nmaps keys to tablets / ranges"];
  consensus [label="Consensus replicates data\nand elects leaders", fillcolor="#D8F3DC", color="#2D6A4F"];
  txn [label="Distributed transaction and\nstrong consistency are built into\nthe storage/control plane", fillcolor="#FFF4D6", color="#C08400"];
  compat [label="Compatibility is practical,\nnot identical to upstream PG", fillcolor="#FDE2E4", color="#B23A48"];

  proto -> plan -> consensus -> txn -> compat;
}
DOT

render "multi_master_framework" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=LR, labelloc=t, fontsize=18, pad=0.25, nodesep=0.5, ranksep=1.0, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  app1 [label="Region A writers", fillcolor="#FFF4D6", color="#C08400"];
  app2 [label="Region B writers", fillcolor="#FFF4D6", color="#C08400"];
  node1 [label="PostgreSQL node A\nBDR / pglogical / Bucardo", fillcolor="#D8F3DC", color="#2D6A4F"];
  node2 [label="PostgreSQL node B\nBDR / pglogical / Bucardo", fillcolor="#D8F3DC", color="#2D6A4F"];
  node3 [label="Optional node C", fillcolor="#D8F3DC", color="#2D6A4F"];
  rules [label="Conflict policy /\nreplication set", fillcolor="#F1E7FF", color="#7B2CBF"];

  app1 -> node1;
  app2 -> node2;
  node1 -> node2 [label="logical changes"];
  node2 -> node1 [label="logical changes"];
  node1 -> node3 [style=dashed, label="optional"];
  node2 -> node3 [style=dashed, label="optional"];
  rules -> node1 [style=dashed];
  rules -> node2 [style=dashed];
}
DOT

render "multi_master_principle" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=TB, labelloc=t, fontsize=18, pad=0.25, nodesep=0.45, ranksep=0.8, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  local [label="Each node commits writes\nlocally first"];
  ship [label="Logical replication ships\nchanges asynchronously"];
  conflict [label="When peers modify same row,\nconflict detection is required", fillcolor="#FDE2E4", color="#B23A48"];
  resolve [label="Resolver keeps local / remote\nor custom business rule", fillcolor="#F1E7FF", color="#7B2CBF"];
  limit [label="Global serializability is weak;\napplication must avoid hot conflicts", fillcolor="#FFF4D6", color="#C08400"];

  local -> ship -> conflict -> resolve -> limit;
}
DOT
