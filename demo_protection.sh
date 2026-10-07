#!/usr/bin/env bash
# 连续传力保护演示：保护受阻 → 保护期间不得拆件/断唯一永久路径（即使临时支撑
# 仍承重）→ 先接通备用永久路径再改接、停用旧支承点 → 预案逐步反映保护与改接
# 顺序、失败不落库 → 保护变更使旧凭据失效 → 解除保护后按普通施工期规则施工 →
# 试载、卸撑、快照如常。
#
# 场景：北柱础 S1、南台基 S2；承重梁 C1 经榫卯 J1 落在 S1 上，小金柱 C2 经
#       JC—C1 搭在承重梁上；J2(S2—C1) 为预登记的备用永久路径，T1(S2—C1)、
#       T2(S2—C2) 为临时支撑。保护 C1 后，J1 是它的唯一永久路径。
#
# 用法：BASE=http://localhost:8080 ./demo_protection.sh
# 注意：请在空库上运行（如 docker compose 首次启动，或另设 APP_DB 的实例）。
set -euo pipefail
BASE="${BASE:-http://localhost:8080}"

api() {  # api METHOD PATH [JSON]：请求行打印到 stderr，stdout 只留响应便于解析
  local method="$1" path="$2" data="${3:-}"
  echo "==> $method $path ${data}" >&2
  if [ -n "$data" ]; then
    curl -sS -w '\nHTTP %{http_code}\n' -X "$method" "$BASE$path" \
      -H 'Content-Type: application/json' -d "$data"
  else
    curl -sS -w '\nHTTP %{http_code}\n' -X "$method" "$BASE$path"
  fi
  echo
}

expect() {  # expect FILE 期望状态码 描述
  local file="$1" want="$2"; shift 2
  local code
  code="$(grep -E '^HTTP [0-9]+$' "$file" | tail -n 1)"
  if [ "$code" != "HTTP $want" ]; then
    echo "断言失败（$*）：期望 $want，实际 '$code'，完整响应见 $file" >&2
    cat "$file" >&2
    exit 1
  fi
  echo "✔ $* → $want"
}

field() {  # field FILE PYTHON_EXPR：对响应首行 JSON 求值
  head -n 1 "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print($2)"
}

echo "---- 1. 登记：S1/S2、C1（J1 落在 S1）、C2（JC 搭在 C1）、备用永久路径 J2、临时支撑 T1/T2 ----"
api POST /supports      '{"id":"S1","name":"北柱础"}'
api POST /supports      '{"id":"S2","name":"南台基"}'
api POST /components    '{"id":"C1","name":"承重梁","min_load":10}'
api POST /components    '{"id":"C2","name":"小金柱","min_load":8}'
api POST /connections   '{"id":"J1","a":"S1","b":"C1"}'
api POST /connections   '{"id":"J2","a":"S2","b":"C1","in_place":false}'   # 备用永久路径
api POST /connections   '{"id":"JC","a":"C1","b":"C2"}'
api POST /temp-supports '{"id":"T1","a":"S2","b":"C1"}'                    # 改接保险支撑
api POST /temp-supports '{"id":"T2","a":"S2","b":"C2"}'                    # 保护受阻演示用

echo "---- 2. 保护受阻：仅靠临时支撑承重的构件不能列为保护对象（临时支撑不能替代永久路径）----"
api POST /steps '{"seq":1,"action":"install","target":"temp_support","id":"T2"}' | tee /tmp/pt_t2.txt
expect /tmp/pt_t2.txt 201 "搭设 T2，此时 C2 同时有永久(JC→C1→S1)与临时路径"
api POST /steps '{"seq":2,"action":"disassemble","target":"connection","id":"JC"}' | tee /tmp/pt_jc_off.txt
expect /tmp/pt_jc_off.txt 201 "卸下 JC：C2 仅剩 T2→S2 临时路径（施工期仍可达），版本 v1"
api POST /steps '{"seq":3,"action":"protect","component":"C2"}' | tee /tmp/pt_block.txt
expect /tmp/pt_block.txt 409 "保护受阻：C2 无法仅凭永久连接抵达在用支承点"
head -n 1 /tmp/pt_block.txt | grep -q '"error": "protect_unreachable"' \
  && head -n 1 /tmp/pt_block.txt | grep -q '"first_affected_component": "C2"' \
  && echo "✔ 409 语义：protect_unreachable，first_affected_component=C2"
api GET /state | tee /tmp/pt_state0.txt
[ "$(field /tmp/pt_state0.txt 'len(d["protections"])')" = "0" ] \
  && [ "$(field /tmp/pt_state0.txt 'd["last_seq"]')" = "2" ] \
  && echo "✔ 受阻不占号、不落下保护：last_seq 仍 2，/state protections 为空（旧库默认同样无保护对象）"

echo "---- 3. 恢复 C2 永久路径后保护 C1（C1 当前仅凭 J1→S1 永久抵达）----"
api POST /steps '{"seq":3,"action":"install","target":"connection","id":"JC"}' | tee /tmp/pt_jc_on.txt
expect /tmp/pt_jc_on.txt 201 "装回 JC，C2 恢复永久路径（版本 v2）"
api POST /steps '{"seq":4,"action":"protect","component":"C1"}' | tee /tmp/pt_protect.txt
expect /tmp/pt_protect.txt 201 "保护 C1 成功（seq 4，不递增连接状态版本）"
api GET /state | tee /tmp/pt_state1.txt
[ "$(field /tmp/pt_state1.txt 'd["version"]')" = "2" ] \
  && [ "$(field /tmp/pt_state1.txt 'd["protections"][0]["component"]')" = "C1" ] \
  && [ "$(field /tmp/pt_state1.txt '[c for c in d["components"] if c["id"]=="C1"][0]["protected"]')" = "True" ] \
  && echo "✔ 保护不改连接版本（仍 v2：装/拆 JC 各 +1）；/state 标记 C1 protected"

echo "---- 4. 保护期间：先搭临时支撑 T1 作保险，但断唯一永久路径/停用唯一支承点仍被整步拒绝 ----"
api POST /steps '{"seq":5,"action":"install","target":"temp_support","id":"T1"}' | tee /tmp/pt_t1.txt
expect /tmp/pt_t1.txt 201 "搭设改接保险支撑 T1（seq 5，不递增版本）"
api POST /steps '{"seq":6,"action":"disassemble","target":"connection","id":"J1"}' | tee /tmp/pt_cut.txt
expect /tmp/pt_cut.txt 409 "拆掉唯一永久路径 J1：即使 T1 仍承重也拒绝（unreachable）"
head -n 1 /tmp/pt_cut.txt | grep -q '"first_affected_component": "C1"' \
  && echo "✔ 指出首个受影响构件 C1（受保护，永久路径被断）"
api POST /steps '{"seq":6,"action":"deactivate_support","id":"S1"}' | tee /tmp/pt_deact.txt
expect /tmp/pt_deact.txt 409 "停用唯一在用支承点 S1：T1 经 S2 仍承重也拒绝（unreachable）"
api POST /steps '{"seq":6,"action":"disassemble","target":"component","id":"C1"}' | tee /tmp/pt_dism.txt
expect /tmp/pt_dism.txt 409 "保护期间不得拆卸 C1（protected）"
head -n 1 /tmp/pt_dism.txt | grep -q '"error": "protected"' \
  && echo "✔ 409 protected：须先按工序 unprotect 解除保护"
api GET /state | tee /tmp/pt_state2.txt
[ "$(field /tmp/pt_state2.txt 'd["last_seq"]')" = "5" ] \
  && [ "$(field /tmp/pt_state2.txt '[c for c in d["connections"] if c["id"]=="J1"][0]["in_place"]')" = "True" ] \
  && [ "$(field /tmp/pt_state2.txt '[s for s in d["supports_detail"] if s["id"]=="S1"][0]["active"]')" = "True" ] \
  && echo "✔ 三次拒绝整步不留改动：last_seq 仍 5，J1 仍在位、S1 仍在用"

echo "---- 5. 绕行改接：先接通备用永久路径 J2(S2—C1)，再拆旧 J1、停用旧支承点 S1 ----"
api POST /steps '{"seq":6,"action":"install","target":"connection","id":"J2"}' | tee /tmp/pt_j2.txt
expect /tmp/pt_j2.txt 201 "接通备用永久路径 J2（seq 6，版本 → v3）"
api POST /steps '{"seq":7,"action":"disassemble","target":"connection","id":"J1"}' | tee /tmp/pt_j1_off.txt
expect /tmp/pt_j1_off.txt 201 "两条永久路径齐备后拆旧路 J1（seq 7 改接放行，版本 → v4）"
api POST /steps '{"seq":8,"action":"deactivate_support","id":"S1"}' | tee /tmp/pt_s1_off.txt
expect /tmp/pt_s1_off.txt 201 "停用旧支承点 S1：C1 仍经 J2→S2 永久抵达（seq 8，版本 → v5）"
api GET /state | tee /tmp/pt_state3.txt
[ "$(field /tmp/pt_state3.txt '[c for c in d["components"] if c["id"]=="C1"][0]["permanent_reachable"]')" = "True" ] \
  && [ "$(field /tmp/pt_state3.txt '[s for s in d["supports_detail"] if s["id"]=="S1"][0]["active"]')" = "False" ] \
  && echo "✔ 改接后 C1 仍仅凭永久连接可达；S1 已停用检修"

echo "---- 6. 预案逐步反映保护与改接顺序：失败预演不落库，成功预演签发凭据 ----"
api POST /plan/preview '{"steps":[{"action":"disassemble","target":"connection","id":"J2"}]}' | tee /tmp/pt_pv_block.txt
expect /tmp/pt_pv_block.txt 409 "失败预演：C1 受保护，拆其唯一永久路径 J2 → unreachable"
head -n 1 /tmp/pt_pv_block.txt | grep -q '"failed_step": {"index": 0, "seq": 9, "action": "disassemble"}' \
  && echo "✔ failed_step={index:0, seq:9, action:disassemble}，不签发凭据"
api POST /plan/preview '{"steps":[
  {"action":"activate_support","id":"S1"},
  {"action":"install","target":"connection","id":"J1"},
  {"action":"disassemble","target":"connection","id":"J2"}
]}' | tee /tmp/pt_pv_ok.txt
expect /tmp/pt_pv_ok.txt 200 "成功预演：启用 S1 → 接 J1 备用永久路径 → 再拆 J2，逐步反映改接顺序"
[ "$(field /tmp/pt_pv_ok.txt 'd["steps"][0]["result"]["version"]')" = "6" ] \
  && [ "$(field /tmp/pt_pv_ok.txt 'd["steps"][2]["result"]["connection"]')" = "J2" ] \
  && echo "✔ 预演结果逐步可见版本递进（v6/7/8）与改接回执"
TOKEN="$(field /tmp/pt_pv_ok.txt "d['token']")"
api GET /state | tee /tmp/pt_state4.txt
[ "$(field /tmp/pt_state4.txt 'd["last_seq"]')" = "8" ] \
  && [ "$(field /tmp/pt_state4.txt 'd["version"]')" = "5" ] \
  && echo "✔ 预演不落库：last_seq 仍 8、版本仍 v5、S1 仍停用"

echo "---- 7. 确认成功落库（seq 9..11），凭据整单仅可用一次 ----"
api POST /plan/confirm "{\"steps\":[
  {\"action\":\"activate_support\",\"id\":\"S1\"},
  {\"action\":\"install\",\"target\":\"connection\",\"id\":\"J1\"},
  {\"action\":\"disassemble\",\"target\":\"connection\",\"id\":\"J2\"}
],\"token\":\"$TOKEN\"}" | tee /tmp/pt_cf_ok.txt
expect /tmp/pt_cf_ok.txt 201 "确认：改接工序按序落库（启用 S1、装 J1、拆 J2）"
[ "$(field /tmp/pt_cf_ok.txt '[r["seq"] for r in d["receipts"]]')" = "[9, 10, 11]" ] \
  && echo "✔ 回执 seq 9..11，C1 受保护且改经 J1→S1 永久抵达"

echo "---- 8. 保护变更使旧凭据失效：预演解除保护后另走 /steps 解除，原凭据 plan_stale ----"
api POST /plan/preview '{"steps":[{"action":"unprotect","component":"C1"}]}' | tee /tmp/pt_pv_un.txt
expect /tmp/pt_pv_un.txt 200 "预演解除 C1 保护并取得凭据"
TOKEN2="$(field /tmp/pt_pv_un.txt "d['token']")"
api POST /steps '{"seq":12,"action":"unprotect","component":"C1"}' | tee /tmp/pt_unprotect.txt
expect /tmp/pt_unprotect.txt 201 "经 /steps 解除 C1 保护（seq 12，保护状态发生变化）"
api POST /plan/confirm "{\"steps\":[{\"action\":\"unprotect\",\"component\":\"C1\"}],\"token\":\"$TOKEN2\"}" | tee /tmp/pt_cf_stale.txt
expect /tmp/pt_cf_stale.txt 409 "保护/工序状态变化使原凭据失效（plan_stale），不写入任何工序"
api GET /state | tee /tmp/pt_state5.txt
[ "$(field /tmp/pt_state5.txt 'd["last_seq"]')" = "12" ] \
  && [ "$(field /tmp/pt_state5.txt 'len(d["protections"])')" = "0" ] \
  && [ "$(field /tmp/pt_state5.txt '[c for c in d["components"] if c["id"]=="C1"][0]["protected"]')" = "False" ] \
  && echo "✔ 保护已解除：protections 为空，C1.protected=false"

echo "---- 9. 解除后施工：C1 回到普通施工期规则，仅剩临时支撑也允许拆永久连接 ----"
api POST /steps '{"seq":13,"action":"disassemble","target":"connection","id":"J1"}' | tee /tmp/pt_j1_cut.txt
expect /tmp/pt_j1_cut.txt 201 "解除后拆 J1：C1 经 T1→S2 仍有施工期支承（普通规则放行，版本 → v9）"
api GET /state | tee /tmp/pt_state6.txt
[ "$(field /tmp/pt_state6.txt '[c for c in d["components"] if c["id"]=="C1"][0]["reachable"]')" = "True" ] \
  && [ "$(field /tmp/pt_state6.txt '[c for c in d["components"] if c["id"]=="C1"][0]["permanent_reachable"]')" = "False" ] \
  && echo "✔ C1 施工期可达但永久不可达（仅靠 T1 临时支撑）"
api POST /steps '{"seq":14,"action":"remove_support","id":"T1"}' | tee /tmp/pt_rm_block.txt
expect /tmp/pt_rm_block.txt 409 "无永久路径即卸撑仍按原规则拒绝（support_unreachable）"
api POST /steps '{"seq":14,"action":"install","target":"connection","id":"J1"}' | tee /tmp/pt_j1_back.txt
expect /tmp/pt_j1_back.txt 201 "装回 J1 恢复永久路径（seq 14，版本 → v10，旧试载失效）"

echo "---- 10. 原试载、卸撑、快照流程可用；快照含 protections 字段 ----"
api POST /steps '{"seq":15,"action":"test_load","component":"C1","load":12}'   | tee /tmp/pt_tl1.txt
expect /tmp/pt_tl1.txt 201 "C1 在 v10 下合格试载"
api POST /steps '{"seq":16,"action":"test_load","component":"C2","load":9}'    | tee /tmp/pt_tl2.txt
expect /tmp/pt_tl2.txt 201 "C2 在 v10 下合格试载"
api POST /steps '{"seq":17,"action":"remove_support","id":"T1"}' | tee /tmp/pt_rm1.txt
expect /tmp/pt_rm1.txt 201 "卸除 T1（C1/C2 均仅凭永久连接抵达）"
api POST /steps '{"seq":18,"action":"remove_support","id":"T2"}' | tee /tmp/pt_rm2.txt
expect /tmp/pt_rm2.txt 201 "卸除 T2"
api POST /snapshots '{}' | tee /tmp/pt_snap.txt
expect /tmp/pt_snap.txt 201 "固化验收快照（只增不改）"
[ "$(field /tmp/pt_snap.txt 'd["version"]')" = "10" ] \
  && echo "✔ 快照落在 v10"
api GET /snapshots/1 | tee /tmp/pt_snap_get.txt
[ "$(field /tmp/pt_snap_get.txt 'd["protections"]')" = "[]" ] \
  && [ "$(field /tmp/pt_snap_get.txt 'sorted(c["id"] for c in d["components"])')" = "['C1', 'C2']" ] \
  && echo "✔ 快照含 protections=[]（解除后无保护对象），C1/C2 均带 v10 合格试载"

echo "✔ 连续传力保护流程完成：保护受阻 → 断唯一永久路径/停用唯一支承点/拆件被拒 → 先接备用永久路径改接 → 预案顺序与凭据失效 → 解除后施工 → 试载/卸撑/快照。"
