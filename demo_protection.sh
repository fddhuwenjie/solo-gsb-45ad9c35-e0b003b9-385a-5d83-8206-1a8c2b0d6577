#!/usr/bin/env bash
# 连续传力保护演示：列入受阻 → 保护期间拆卸/断唯一永久路径/停唯一支承点受阻 →
#                 先接通备用永久路径后改接 → 解除后按原规则施工 →
#                 预案中的保护与改接 → 保护变更使旧凭据失效 → 原卸撑快照流程。
#
# 场景：北柱础 S1、南台基 S2 两个在用支承点；承重梁 C1 经榫卯 J1 落在 S1 上，
#       横梁 C2 经 J2 挂在 C1 上，斗拱 C3 只搭了临时支撑 T2（无永久连接）。
#       J3（S2—C1）为预登记的改接组合，J4（S2—C3）留待收尾接入。
#       保护中的构件每道后续工序结束时都须仅凭当时在位的永久连接抵达在用
#       支承点——临时支撑不计入；先接通备用永久路径后才允许改接。
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

echo "---- 1. 登记：S1/S2 支承点、C1/C2/C3 构件、榫卯与临时支撑 ----"
api POST /supports      '{"id":"S1","name":"北柱础"}'
api POST /supports      '{"id":"S2","name":"南台基"}'
api POST /components    '{"id":"C1","name":"承重梁","min_load":10}'
api POST /components    '{"id":"C2","name":"横梁","min_load":6}'
api POST /components    '{"id":"C3","name":"斗拱","min_load":4}'
api POST /connections   '{"id":"J1","a":"S1","b":"C1"}'
api POST /connections   '{"id":"J2","a":"C1","b":"C2"}'
api POST /connections   '{"id":"J3","a":"S2","b":"C1","in_place":false}'   # 预登记改接组合
api POST /connections   '{"id":"J4","a":"S2","b":"C3","in_place":false}'   # 收尾接入斗拱
api POST /temp-supports '{"id":"T1","a":"S2","b":"C1"}'
api POST /temp-supports '{"id":"T2","a":"S2","b":"C3"}'

echo "---- 2. 列入受阻：C3 仅凭临时支撑抵达支承点，不能列为保护对象 ----"
api POST /steps '{"seq":1,"action":"install","target":"temp_support","id":"T2"}' | tee /tmp/pt_t2.txt
expect /tmp/pt_t2.txt 201 "搭设临时支撑 T2（seq 1）"
api POST /steps '{"seq":2,"action":"protect","id":"C3"}' | tee /tmp/pt_protect_c3.txt
expect /tmp/pt_protect_c3.txt 409 "列入受阻：C3 无永久路径（protected_unreachable）"
head -n 1 /tmp/pt_protect_c3.txt | grep -q '"error": "protected_unreachable"' \
  && head -n 1 /tmp/pt_protect_c3.txt | grep -q '"first_affected_component": "C3"' \
  && echo "✔ 409 语义：protected_unreachable，first_affected_component=C3"

echo "---- 3. 保护 C1：当前仅凭 J1 永久连接抵达 S1，列入成功；/state 可查 ----"
api POST /steps '{"seq":2,"action":"protect","id":"C1"}' | tee /tmp/pt_protect.txt
expect /tmp/pt_protect.txt 201 "C1 列为连续传力保护对象（seq 2）"
api POST /steps '{"seq":3,"action":"protect","id":"C1"}' | tee /tmp/pt_protect2.txt
expect /tmp/pt_protect2.txt 409 "重复列入被拒（already_protected）"
api GET /state | tee /tmp/pt_state1.txt
[ "$(field /tmp/pt_state1.txt "d['protected_components']")" = "['C1']" ] \
  && [ "$(field /tmp/pt_state1.txt "d['components'][0]['protected']")" = "True" ] \
  && [ "$(field /tmp/pt_state1.txt "d['version']")" = "0" ] \
  && echo "✔ /state 显示 C1 保护中（protected_components）；保护不改变连接状态版本"

echo "---- 4. 保护期间不得拆卸该构件 ----"
api POST /steps '{"seq":3,"action":"disassemble","target":"component","id":"C1"}' | tee /tmp/pt_dis_c1.txt
expect /tmp/pt_dis_c1.txt 409 "拆卸保护中的 C1 被拒（component_protected）"

echo "---- 5. 即使临时支撑仍能承重：断唯一永久路径、停唯一支承点均按 409 拒绝 ----"
api POST /steps '{"seq":3,"action":"install","target":"temp_support","id":"T1"}' | tee /tmp/pt_t1.txt
expect /tmp/pt_t1.txt 201 "搭设临时支撑 T1（seq 3，C1 施工期可达性由 T1 兜底）"
api POST /steps '{"seq":4,"action":"disassemble","target":"connection","id":"J1"}' | tee /tmp/pt_dis_j1.txt
expect /tmp/pt_dis_j1.txt 409 "拆唯一永久路径 J1 被拒（protected_unreachable）"
head -n 1 /tmp/pt_dis_j1.txt | grep -q '"first_affected_component": "C1"' \
  && echo "✔ 指出首个受影响构件 C1"
api POST /steps '{"seq":4,"action":"deactivate_support","id":"S1"}' | tee /tmp/pt_deact.txt
expect /tmp/pt_deact.txt 409 "停用唯一支承点 S1 同样被拒（protected_unreachable）"
api GET /state | tee /tmp/pt_state2.txt
[ "$(field /tmp/pt_state2.txt "d['last_seq']")" = "3" ] \
  && [ "$(field /tmp/pt_state2.txt "d['connections'][0]['in_place']")" = "True" ] \
  && [ "$(field /tmp/pt_state2.txt "d['supports_detail'][0]['active']")" = "True" ] \
  && echo "✔ 整步不留改动：last_seq=3，J1 仍在位，S1 仍在用"

echo "---- 6. 先接通备用永久路径后允许改接 ----"
api POST /steps '{"seq":4,"action":"install","target":"connection","id":"J3"}' | tee /tmp/pt_j3.txt
expect /tmp/pt_j3.txt 201 "接通备用永久路径 J3（S2—C1，seq 4）"
api POST /steps '{"seq":5,"action":"disassemble","target":"connection","id":"J1"}' | tee /tmp/pt_dis_j1b.txt
expect /tmp/pt_dis_j1b.txt 201 "改接允许：C1 仅凭 J3→S2 永久路径，拆 J1 放行（seq 5）"

echo "---- 7. 解除保护后按原施工期规则施工 ----"
api POST /steps '{"seq":6,"action":"unprotect","id":"C1"}' | tee /tmp/pt_unprotect.txt
expect /tmp/pt_unprotect.txt 201 "解除 C1 保护（seq 6）"
api POST /steps '{"seq":7,"action":"unprotect","id":"C1"}' | tee /tmp/pt_unprotect2.txt
expect /tmp/pt_unprotect2.txt 409 "重复解除被拒（not_protected）"
api POST /steps '{"seq":7,"action":"disassemble","target":"connection","id":"J3"}' | tee /tmp/pt_dis_j3.txt
expect /tmp/pt_dis_j3.txt 201 "解除后施工：C1 仅靠 T1 临时支撑亦合原规则，拆 J3 放行（seq 7）"
api POST /steps '{"seq":8,"action":"install","target":"connection","id":"J1"}' | tee /tmp/pt_j1b.txt
expect /tmp/pt_j1b.txt 201 "恢复 J1（seq 8），为预案演示铺垫"

echo "---- 8. 预案逐步反映保护与改接顺序；失败不落库 ----"
api POST /plan/preview '{"steps":[
  {"action":"protect","id":"C1"},
  {"action":"disassemble","target":"component","id":"C1"}
]}' | tee /tmp/pt_pv_block.txt
expect /tmp/pt_pv_block.txt 409 "失败预演：前步保护后拆卸被拒（component_protected）"
head -n 1 /tmp/pt_pv_block.txt | grep -q '"failed_step": {"index": 1, "seq": 10, "action": "disassemble"}' \
  && echo "✔ failed_step={index:1, seq:10, action:disassemble}"
STEPS='[
  {"action":"protect","id":"C1"},
  {"action":"install","target":"connection","id":"J3"},
  {"action":"disassemble","target":"connection","id":"J1"},
  {"action":"unprotect","id":"C1"}
]'
api POST /plan/preview "{\"steps\":$STEPS}" | tee /tmp/pt_pv_ok.txt
expect /tmp/pt_pv_ok.txt 200 "成功预演：保护 → 接通备用路径 → 改接 → 解除，签发凭据"
TOKEN="$(field /tmp/pt_pv_ok.txt "d['token']")"
api GET /state | tee /tmp/pt_state3.txt
[ "$(field /tmp/pt_state3.txt "d['last_seq']")" = "8" ] \
  && [ "$(field /tmp/pt_state3.txt "d['protected_components']")" = "[]" ] \
  && echo "✔ 预演不落库：last_seq=8，仍无保护对象"
api POST /plan/confirm "{\"steps\":$STEPS,\"token\":\"$TOKEN\"}" | tee /tmp/pt_cf_ok.txt
expect /tmp/pt_cf_ok.txt 201 "确认成功：保护与改接工序按序落库（seq 9..12）"

echo "---- 9. 保护变更使旧凭据失效 ----"
Q='[{"action":"test_load","component":"C1","load":12}]'
api POST /plan/preview "{\"steps\":$Q}" | tee /tmp/pt_pv_q.txt
expect /tmp/pt_pv_q.txt 200 "预演取得凭据"
TOKEN2="$(field /tmp/pt_pv_q.txt "d['token']")"
api POST /steps '{"seq":13,"action":"protect","id":"C1"}' | tee /tmp/pt_protect3.txt
expect /tmp/pt_protect3.txt 201 "预演后经 /steps 再次保护 C1（seq 13）"
api POST /plan/confirm "{\"steps\":$Q,\"token\":\"$TOKEN2\"}" | tee /tmp/pt_cf_stale.txt
expect /tmp/pt_cf_stale.txt 409 "保护变更使旧凭据失效（plan_stale），不写入任何工序"
api POST /steps '{"seq":14,"action":"unprotect","id":"C1"}' | tee /tmp/pt_unprotect3.txt
expect /tmp/pt_unprotect3.txt 201 "解除保护（seq 14）"

echo "---- 10. 原试载、卸撑、快照流程照常可用 ----"
api POST /steps '{"seq":15,"action":"install","target":"connection","id":"J4"}' | tee /tmp/pt_j4.txt
expect /tmp/pt_j4.txt 201 "接入斗拱永久路径 J4（seq 15）"
api POST /steps '{"seq":16,"action":"test_load","component":"C1","load":12}' | tee /tmp/pt_tl1.txt
expect /tmp/pt_tl1.txt 201 "C1 合格试载"
api POST /steps '{"seq":17,"action":"test_load","component":"C2","load":7}' | tee /tmp/pt_tl2.txt
expect /tmp/pt_tl2.txt 201 "C2 合格试载"
api POST /steps '{"seq":18,"action":"test_load","component":"C3","load":5}' | tee /tmp/pt_tl3.txt
expect /tmp/pt_tl3.txt 201 "C3 合格试载"
api POST /steps '{"seq":19,"action":"remove_support","id":"T1"}' | tee /tmp/pt_rm1.txt
expect /tmp/pt_rm1.txt 201 "卸撑 T1（seq 19）"
api POST /steps '{"seq":20,"action":"remove_support","id":"T2"}' | tee /tmp/pt_rm2.txt
expect /tmp/pt_rm2.txt 201 "卸撑 T2（seq 20）"
api POST /snapshots '{}' | tee /tmp/pt_snap.txt
expect /tmp/pt_snap.txt 201 "固化验收快照"

echo "✔ 连续传力保护流程完成：列入受阻 → 保护期三类受阻 → 备用路径改接 → 解除后施工 → 预案保护与凭据失效 → 卸撑快照。"
