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

render "streaming_replication_framework" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=LR, labelloc=t, fontsize=18, pad=0.25, nodesep=0.45, ranksep=0.9, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2, margin="0.18,0.10"];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  client [label="Application / Client", fillcolor="#FFF4D6", color="#C08400"];
  router [label="VIP / HAProxy / App DNS", fillcolor="#FFF4D6", color="#C08400"];
  primary [label="Primary PostgreSQL\nread-write", fillcolor="#D8F3DC", color="#2D6A4F"];
  standby1 [label="Standby PostgreSQL\nhot standby", fillcolor="#EAF2FF"];
  standby2 [label="Standby PostgreSQL\noptional cascade", fillcolor="#EAF2FF"];

  client -> router [label="connect"];
  router -> primary [label="write traffic"];
  primary -> standby1 [label="streaming WAL"];
  standby1 -> standby2 [label="cascade WAL", style=dashed];
}
DOT

render "streaming_replication_principle" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=LR, labelloc=t, fontsize=18, pad=0.25, nodesep=0.45, ranksep=0.9, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2, margin="0.18,0.10"];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  tx [label="Transaction commit\non primary", fillcolor="#D8F3DC", color="#2D6A4F"];
  wal [label="Primary WAL / pg_wal"];
  sender [label="walsender"];
  receiver [label="walreceiver"];
  standbywal [label="Standby WAL / pg_wal"];
  startup [label="startup process\nreplay WAL"];
  ro [label="Standby becomes\nqueryable replica", fillcolor="#FFF4D6", color="#C08400"];
  promote [label="Failover:\npg_promote()", shape=diamond, fillcolor="#FDE2E4", color="#B23A48"];

  tx -> wal -> sender -> receiver -> standbywal -> startup -> ro;
  ro -> promote [style=dashed, label="primary down"];
}
DOT

render "patroni_framework" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=LR, labelloc=t, fontsize=18, pad=0.25, nodesep=0.5, ranksep=1.0, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  client [label="Application / Client", fillcolor="#FFF4D6", color="#C08400"];
  proxy [label="HAProxy / PgBouncer / VIP", fillcolor="#FFF4D6", color="#C08400"];
  dcs [label="DCS\netcd / Consul / ZooKeeper", shape=cylinder, fillcolor="#F1E7FF", color="#7B2CBF"];
  primary [label="Patroni + PostgreSQL\nleader / primary", fillcolor="#D8F3DC", color="#2D6A4F"];
  standby1 [label="Patroni + PostgreSQL\nreplica", fillcolor="#EAF2FF"];
  standby2 [label="Patroni + PostgreSQL\nreplica", fillcolor="#EAF2FF"];

  client -> proxy -> primary;
  primary -> standby1 [label="streaming replication"];
  primary -> standby2 [label="streaming replication"];
  dcs -> primary [dir=both, label="leader key + status"];
  dcs -> standby1 [dir=both, label="state"];
  dcs -> standby2 [dir=both, label="state"];
}
DOT

render "patroni_principle" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=TB, labelloc=t, fontsize=18, pad=0.25, nodesep=0.45, ranksep=0.8, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  check [label="Each Patroni agent checks\nlocal PostgreSQL health"];
  renew [label="Leader renews DCS lock\nwithin TTL", fillcolor="#D8F3DC", color="#2D6A4F"];
  expire [label="Leader lock expires\nor node loses quorum", shape=diamond, fillcolor="#FDE2E4", color="#B23A48"];
  race [label="Healthy replicas race for\nnew leader key"];
  promote [label="Winner promotes itself\nand updates cluster state", fillcolor="#D8F3DC", color="#2D6A4F"];
  reroute [label="Proxies / clients reconnect\nto the new primary", fillcolor="#FFF4D6", color="#C08400"];
  follow [label="Remaining replicas follow\nnew primary"];

  check -> renew -> expire -> race -> promote -> reroute;
  promote -> follow;
}
DOT

render "repmgr_framework" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=LR, labelloc=t, fontsize=18, pad=0.25, nodesep=0.5, ranksep=1.0, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  app [label="Application / Client", fillcolor="#FFF4D6", color="#C08400"];
  vip [label="VIP / HAProxy / DNS", fillcolor="#FFF4D6", color="#C08400"];
  primary [label="repmgrd + PostgreSQL\nprimary", fillcolor="#D8F3DC", color="#2D6A4F"];
  standby [label="repmgrd + PostgreSQL\nstandby", fillcolor="#EAF2FF"];
  witness [label="repmgr witness\nmetadata + quorum", fillcolor="#F1E7FF", color="#7B2CBF"];
  meta [label="repmgr metadata\nnode registry", shape=cylinder, fillcolor="#F1E7FF", color="#7B2CBF"];

  app -> vip -> primary;
  primary -> standby [label="streaming replication"];
  primary -> meta [label="register"];
  standby -> meta [label="register"];
  witness -> meta [label="observe quorum"];
}
DOT

render "repmgr_principle" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=TB, labelloc=t, fontsize=18, pad=0.25, nodesep=0.45, ranksep=0.8, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  monitor [label="repmgrd monitors primary\nreachability and lag"];
  judge [label="Witness / policy confirms\nfailover conditions", shape=diamond, fillcolor="#FDE2E4", color="#B23A48"];
  promote [label="Chosen standby runs\nrepmgr standby promote", fillcolor="#D8F3DC", color="#2D6A4F"];
  register [label="Cluster metadata updated\nwith new primary"];
  follow [label="Other standbys execute\nrepmgr standby follow"];
  switch [label="Client entrypoint switches\nby VIP / DNS / proxy", fillcolor="#FFF4D6", color="#C08400"];

  monitor -> judge -> promote -> register -> follow -> switch;
}
DOT

render "pacemaker_framework" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=LR, labelloc=t, fontsize=18, pad=0.25, nodesep=0.5, ranksep=1.0, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  client [label="Application / Client", fillcolor="#FFF4D6", color="#C08400"];
  vip [label="VIP resource", fillcolor="#FFF4D6", color="#C08400"];
  pacemaker [label="Pacemaker\npolicy engine", fillcolor="#F1E7FF", color="#7B2CBF"];
  corosync [label="Corosync\ncluster membership", fillcolor="#F1E7FF", color="#7B2CBF"];
  stonith [label="STONITH / fencing", fillcolor="#FDE2E4", color="#B23A48"];
  primary [label="Node A\nPostgreSQL primary", fillcolor="#D8F3DC", color="#2D6A4F"];
  standby [label="Node B\nPostgreSQL standby", fillcolor="#EAF2FF"];

  client -> vip;
  vip -> primary;
  corosync -> pacemaker [label="membership"];
  pacemaker -> primary [label="pgsql resource"];
  pacemaker -> standby [label="pgsql resource"];
  pacemaker -> vip [label="move / assign"];
  pacemaker -> stonith [label="fence failed node"];
  primary -> standby [label="streaming replication"];
}
DOT

render "pacemaker_principle" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=TB, labelloc=t, fontsize=18, pad=0.25, nodesep=0.45, ranksep=0.8, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  detect [label="Corosync detects node loss\nor resource failure"];
  policy [label="Pacemaker evaluates\nconstraints and scores"];
  fence [label="Fence old primary first", fillcolor="#FDE2E4", color="#B23A48"];
  promote [label="Promote standby resource\nto primary", fillcolor="#D8F3DC", color="#2D6A4F"];
  vip [label="Move VIP / service resource\nto the promoted node", fillcolor="#FFF4D6", color="#C08400"];
  recover [label="Recover old node as\nstandby after validation"];

  detect -> policy -> fence -> promote -> vip -> recover;
}
DOT

render "pgpool_framework" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=LR, labelloc=t, fontsize=18, pad=0.25, nodesep=0.5, ranksep=1.0, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  app [label="Application / Client", fillcolor="#FFF4D6", color="#C08400"];
  vip [label="pgpool-II VIP / watchdog", fillcolor="#FFF4D6", color="#C08400"];
  pgpool [label="pgpool-II\npooling + routing", fillcolor="#F1E7FF", color="#7B2CBF"];
  primary [label="PostgreSQL primary", fillcolor="#D8F3DC", color="#2D6A4F"];
  standby1 [label="PostgreSQL standby", fillcolor="#EAF2FF"];
  standby2 [label="PostgreSQL standby", fillcolor="#EAF2FF"];

  app -> vip -> pgpool;
  pgpool -> primary [label="write / DDL"];
  pgpool -> standby1 [label="read"];
  pgpool -> standby2 [label="read"];
  primary -> standby1 [label="streaming replication"];
  primary -> standby2 [label="streaming replication"];
}
DOT

render "pgpool_principle" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=TB, labelloc=t, fontsize=18, pad=0.25, nodesep=0.45, ranksep=0.8, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  pool [label="pgpool accepts client sessions\nand reuses backend connections"];
  parse [label="SQL parser classifies\nread vs write"];
  route [label="Writes -> primary\nReads -> standby", fillcolor="#FFF4D6", color="#C08400"];
  health [label="Health check / sr_check\nmonitors backend state"];
  failover [label="On primary failure,\nrun failover_command", fillcolor="#FDE2E4", color="#B23A48"];
  watchdog [label="watchdog keeps pgpool VIP\non healthy frontend", fillcolor="#D8F3DC", color="#2D6A4F"];

  pool -> parse -> route;
  parse -> health;
  health -> failover -> watchdog;
}
DOT

render "keepalived_framework" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=LR, labelloc=t, fontsize=18, pad=0.25, nodesep=0.5, ranksep=1.0, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  app [label="Application / Client", fillcolor="#FFF4D6", color="#C08400"];
  vip [label="VRRP VIP", fillcolor="#FFF4D6", color="#C08400"];
  primary [label="Keepalived + PostgreSQL\ncurrent primary", fillcolor="#D8F3DC", color="#2D6A4F"];
  standby [label="Keepalived + PostgreSQL\nstandby", fillcolor="#EAF2FF"];
  script [label="check_pg_primary.sh\nrole check", fillcolor="#F1E7FF", color="#7B2CBF"];

  app -> vip -> primary;
  primary -> standby [label="streaming replication"];
  script -> primary [label="pg_is_in_recovery()"];
  script -> standby [label="pg_is_in_recovery()"];
}
DOT

render "keepalived_principle" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=TB, labelloc=t, fontsize=18, pad=0.25, nodesep=0.45, ranksep=0.8, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  check [label="VRRP script checks local role\nand PostgreSQL reachability"];
  hold [label="VIP stays on node that is\nreachable and primary", fillcolor="#D8F3DC", color="#2D6A4F"];
  fail [label="Primary check fails", shape=diamond, fillcolor="#FDE2E4", color="#B23A48"];
  move [label="Backup node acquires VIP\nthrough VRRP election", fillcolor="#FFF4D6", color="#C08400"];
  promote [label="External script or HA manager\nmust promote database", fillcolor="#F1E7FF", color="#7B2CBF"];
  guard [label="Need fencing / split-brain guard\nbefore automatic promotion"];

  check -> hold -> fail -> move -> promote -> guard;
}
DOT

render "logical_replication_framework" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=LR, labelloc=t, fontsize=18, pad=0.25, nodesep=0.5, ranksep=1.0, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  pub [label="Publisher DB\npublication", fillcolor="#D8F3DC", color="#2D6A4F"];
  slot [label="Logical replication slot", shape=cylinder, fillcolor="#F1E7FF", color="#7B2CBF"];
  sub [label="Subscriber DB\nsubscription", fillcolor="#EAF2FF"];
  tbl1 [label="Selected tables only", fillcolor="#FFF4D6", color="#C08400"];
  tbl2 [label="Different version or schema\nwith compatible mapping", fillcolor="#FFF4D6", color="#C08400"];

  pub -> slot [label="decode WAL"];
  slot -> sub [label="logical changes"];
  pub -> tbl1 [style=dashed, arrowhead=none];
  sub -> tbl2 [style=dashed, arrowhead=none];
}
DOT

render "logical_replication_principle" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=TB, labelloc=t, fontsize=18, pad=0.25, nodesep=0.45, ranksep=0.8, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  write [label="Publisher writes rows"];
  decode [label="Logical decoding reads WAL\nthrough output plugin"];
  slot [label="Replication slot retains WAL\nuntil subscriber catches up", fillcolor="#F1E7FF", color="#7B2CBF"];
  send [label="walsender transmits\nINSERT / UPDATE / DELETE"];
  apply [label="Subscriber apply worker\nreplays row changes", fillcolor="#D8F3DC", color="#2D6A4F"];
  extra [label="DDL, sequences, roles,\nextensions handled separately", fillcolor="#FDE2E4", color="#B23A48"];

  write -> decode -> slot -> send -> apply -> extra;
}
DOT

render "bdr_framework" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=LR, labelloc=t, fontsize=18, pad=0.25, nodesep=0.5, ranksep=1.0, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  app1 [label="Writers in region A", fillcolor="#FFF4D6", color="#C08400"];
  node1 [label="Node A\nBDR / pglogical", fillcolor="#D8F3DC", color="#2D6A4F"];
  node2 [label="Node B\nBDR / pglogical", fillcolor="#D8F3DC", color="#2D6A4F"];
  app2 [label="Writers in region B", fillcolor="#FFF4D6", color="#C08400"];
  conflict [label="Conflict handling\nand replication sets", fillcolor="#F1E7FF", color="#7B2CBF"];

  app1 -> node1;
  app2 -> node2;
  node1 -> node2 [label="logical replication"];
  node2 -> node1 [label="logical replication"];
  conflict -> node1 [style=dashed];
  conflict -> node2 [style=dashed];
}
DOT

render "bdr_principle" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=TB, labelloc=t, fontsize=18, pad=0.25, nodesep=0.45, ranksep=0.8, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  write [label="Each node accepts writes\nlocally"];
  queue [label="Changes enter logical\nreplication queue"];
  ship [label="Peers exchange changes\nasynchronously"];
  detect [label="Conflict detector checks\nPK, row version, commit ts", fillcolor="#FDE2E4", color="#B23A48"];
  resolve [label="Configured resolver chooses\nkeep local / keep remote / custom", fillcolor="#F1E7FF", color="#7B2CBF"];
  converge [label="Nodes converge after apply,\nif application design is safe", fillcolor="#D8F3DC", color="#2D6A4F"];

  write -> queue -> ship -> detect -> resolve -> converge;
}
DOT

render "kubernetes_operator_framework" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=LR, labelloc=t, fontsize=18, pad=0.25, nodesep=0.5, ranksep=1.0, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  crd [label="Cluster CRD / YAML", fillcolor="#FFF4D6", color="#C08400"];
  api [label="Kubernetes API Server", fillcolor="#F1E7FF", color="#7B2CBF"];
  operator [label="PostgreSQL Operator\nreconcile loop", fillcolor="#F1E7FF", color="#7B2CBF"];
  rw [label="rw Service", fillcolor="#FFF4D6", color="#C08400"];
  ro [label="ro Service", fillcolor="#FFF4D6", color="#C08400"];
  pods [label="StatefulSet / Pods\nprimary + replicas", fillcolor="#D8F3DC", color="#2D6A4F"];
  pvc [label="PVC / StorageClass / Backup", fillcolor="#EAF2FF"];

  crd -> api -> operator;
  operator -> pods [label="manage cluster"];
  operator -> rw [label="route writer"];
  operator -> ro [label="route readers"];
  operator -> pvc [label="attach storage / backup"];
}
DOT

render "kubernetes_operator_principle" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=TB, labelloc=t, fontsize=18, pad=0.25, nodesep=0.45, ranksep=0.8, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  desired [label="Desired state stored in CRD"];
  watch [label="Operator watches Pods,\nPVCs, Services and roles"];
  fail [label="Primary pod / node failure", shape=diamond, fillcolor="#FDE2E4", color="#B23A48"];
  promote [label="Promote a healthy replica\nand update rw Service", fillcolor="#D8F3DC", color="#2D6A4F"];
  recreate [label="Recreate failed pod\nor reattach storage"];
  heal [label="Cluster returns to desired\ninstance count and topology", fillcolor="#FFF4D6", color="#C08400"];

  desired -> watch -> fail -> promote -> recreate -> heal;
}
DOT

render "managed_cloud_framework" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=LR, labelloc=t, fontsize=18, pad=0.25, nodesep=0.5, ranksep=1.0, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  app [label="Application", fillcolor="#FFF4D6", color="#C08400"];
  endpoint [label="Managed endpoint\nproxy / DNS", fillcolor="#FFF4D6", color="#C08400"];
  ctrl [label="Cloud control plane", fillcolor="#F1E7FF", color="#7B2CBF"];
  primary [label="Managed primary", fillcolor="#D8F3DC", color="#2D6A4F"];
  standby [label="Managed standby / replica", fillcolor="#EAF2FF"];
  backup [label="Automated backup / PITR /\nmetrics / alarms", fillcolor="#EAF2FF"];

  app -> endpoint;
  endpoint -> primary;
  ctrl -> primary [label="operate"];
  ctrl -> standby [label="replicate / failover"];
  ctrl -> backup [label="backup & monitor"];
  primary -> standby [label="managed replication"];
}
DOT

render "managed_cloud_principle" <<'DOT'
digraph G {
  graph [fontname="DejaVu Sans", rankdir=TB, labelloc=t, fontsize=18, pad=0.25, nodesep=0.45, ranksep=0.8, bgcolor="white"];
  node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, color="#355070", fillcolor="#EAF2FF", penwidth=1.2];
  edge [fontname="DejaVu Sans", fontsize=10, color="#4F5D75", penwidth=1.2, arrowsize=0.8];

  monitor [label="Provider control plane monitors\ninstance health and lag"];
  detect [label="Failure detected in AZ / VM /\nprocess / storage path", shape=diamond, fillcolor="#FDE2E4", color="#B23A48"];
  switch [label="Promote standby or switch\nshared storage ownership", fillcolor="#D8F3DC", color="#2D6A4F"];
  route [label="Endpoint / DNS / proxy\nnow points to new primary", fillcolor="#FFF4D6", color="#C08400"];
  reopen [label="Clients reconnect with\nretry-aware logic"];
  protect [label="Backups, snapshots and PITR\ncover data recovery needs", fillcolor="#F1E7FF", color="#7B2CBF"];

  monitor -> detect -> switch -> route -> reopen -> protect;
}
DOT
