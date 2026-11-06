#!/usr/bin/env python3
"""Check the matrix producer and its consumer TOGETHER.

**what?**  `scripts/ci-select-suites.sh` writes `matrix=...`; the workflow feeds it into
`strategy.matrix` via `fromJSON`. This script runs the producer for both the default selection and
an explicitly requested one, reads the consumer out of the real workflow file, and then checks the
*pair*: the shape the producer emits is the shape that consumer accepts.

**why?**  Reviewing `5cc119d` on 2026-11-05 the maintainer found that the producer emitted a bare
JSON array while `strategy.matrix: ${{ fromJSON(...) }}` requires an object - Actions rejects the
whole workflow file, so no matrix job would expand once the credential gate allowed the live job.
Neither side looks wrong in isolation: the selector's own tests only ever asserted the selector.
A contract needs both ends in one assertion.

**when?**  By `./scripts/test-mc-integration-gate.sh`, and by hand:
    python3 tests/gate/matrix_contract.py
    python3 tests/gate/matrix_contract.py --selftest   # the four pairings, two good / two bad

Exit codes are three-state on purpose: 0 = judged, pair agrees; 1 = judged, pair disagrees (or a
suite in the payload has no project directory); 2 = nothing was judged (producer unrunnable,
workflow missing, or the consumer shape could not be read) - never report "fine" or "violation"
for a 2.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent.parent
PRODUCER = REPO / "scripts" / "ci-select-suites.sh"
WORKFLOW = REPO / ".github" / "workflows" / "maxcompute-integration.yml"


def produce(argv, producer=None):
    """Run the real selector (or a given copy of it); return (payload, error)."""
    producer = pathlib.Path(producer) if producer else PRODUCER
    if not producer.is_file():
        return None, "producer 不存在: %s" % producer
    r = subprocess.run(["bash", str(producer)] + list(argv), capture_output=True, text=True, timeout=180)
    if r.returncode != 0:
        return None, "producer rc=%d (%s)" % (r.returncode, (r.stderr or r.stdout).strip()[-120:])
    for line in r.stdout.splitlines():
        if line.startswith("matrix="):
            try:
                return json.loads(line[len("matrix="):]), None
            except ValueError as exc:
                return None, "matrix= 不是合法 JSON: %s" % exc
    return None, "producer 没输出 matrix= 行"


def consumer(workflow_text=None, workflow=None):
    """Return ('object'|'include'|None, detail) for how strategy.matrix consumes the payload."""
    if workflow_text is None:
        wf = pathlib.Path(workflow) if workflow else WORKFLOW
        if not wf.is_file():
            return None, "workflow 文件不存在: %s" % wf
        workflow_text = wf.read_text()
    # 只看 integration job 的 strategy: 块（prepare job 也有 matrix:，那是 outputs 声明，不是消费点）
    m = re.search(r"(?ms)^    integration:\s*$(.*?)(?=^    [A-Za-z_-]+:|\Z)", workflow_text)
    if not m:
        return None, "workflow 里找不到 integration job ⇒ 消费点无法判定"
    block = m.group(1)
    s = re.search(r"(?ms)^\s{8}strategy:\s*$(.*?)(?=^\s{4}\S|\Z)", block)
    if not s:
        return None, "integration job 里没有 strategy: 块 ⇒ 消费点无法判定"
    strat = s.group(1)
    inc = re.search(r"(?m)^\s+include:\s*(\$\{\{.*\}\})\s*$", strat)
    obj = re.search(r"(?m)^\s+matrix:\s*(\$\{\{.*\}\})\s*$", strat)
    if inc and (not obj or inc.start() > obj.start()):
        return "include", inc.group(1)
    if obj:
        return "object", obj.group(1)
    return None, "strategy 块里既没有 matrix: 也没有 include: ⇒ 消费点无法判定"


def judge(payload, mode):
    """The contract itself. Returns (rc, lines)."""
    out = []
    if payload is None:
        return 2, out
    names = {p.parent.name for p in REPO.glob("integration_tests*/dbt_project.yml")}
    if mode == "object":
        if not isinstance(payload, dict):
            out.append("FAIL  consumer 要 object（`strategy.matrix: %s`），producer 给了 %s ⇒ 整个 workflow 会被 Actions 判非法"
                       % (mode, type(payload).__name__))
            out.append("      payload=%s" % json.dumps(payload)[:120])
            return 1, out
        inc = payload.get("include")
        if not isinstance(inc, list) or not inc:
            out.append("FAIL  object 里必须有非空 include 数组，实得 keys=%s" % sorted(payload))
            return 1, out
    elif mode == "include":
        if not isinstance(payload, list):
            out.append("FAIL  consumer 走 `matrix.include`（要数组），producer 给了 %s" % type(payload).__name__)
            return 1, out
        inc = payload
    else:
        return 2, ["UNVERIFIED 消费点判不出来：%s" % mode]
    bad = []
    for item in inc:
        if not isinstance(item, dict) or set(item) != {"suite"}:
            bad.append(repr(item))
        elif item["suite"] not in names:
            bad.append("%s（无该 suite 目录）" % item["suite"])
    if bad:
        out.append("FAIL  include 项形状或 suite 名不对：%s" % "; ".join(bad[:4]))
        return 1, out
    out.append("OK    consumer=%s 接受 producer 形状；%d 个 suite 全部有工程目录：%s"
               % (mode, len(inc), ", ".join(i["suite"] for i in inc)))
    return 0, out


def synth(kind):
    """Synthetic payloads for --selftest, so the check is proved against the bad pair too."""
    return {"array": [{"suite": "integration_tests"}],
            "object": {"include": [{"suite": "integration_tests"}]}}[kind]


def selftest():
    cases = [("array", "object", 1), ("object", "object", 0), ("array", "include", 0),
             ("object", "include", 1), ("array", None, 2)]
    bad = 0
    for pk, mode, want in cases:
        rc, _ = judge(synth(pk) if pk in ("array", "object") else None, mode)
        ok = rc == want
        bad += 0 if ok else 1
        print("SELFTEST producer=%-6s consumer=%-7s want_rc=%d got_rc=%d ok=%s" % (pk, mode, want, rc, ok))
    payload, err = produce(["integration_tests_minimal"])
    rc, _ = judge(payload, "object")
    ok = payload is not None and rc == 0
    bad += 0 if ok else 1
    print("SELFTEST real-producer rc=%d err=%s ok=%s" % (rc, err, ok))
    # 红侧不由合成数据自证：把真 producer 现在产出的 object 剥掉 include 外壳，就还原成
    # 2026-11-05 评审点名的那个裸数组形状，喂给同一个 object 消费者必须被判违规。
    if isinstance(payload, dict) and "include" in payload:
        lrc, _ = judge(list(payload["include"]), "object")
        ok = lrc == 1
        bad += 0 if ok else 1
        print("SELFTEST unwrap-to-legacy-shape rc=%d want=1 ok=%s" % (lrc, ok))
    else:
        print("SELFTEST unwrap-to-legacy-shape SKIP（producer 当前没给 include 外壳，无从还原旧形状）")
        bad += 1
    print("SELFTEST-END fails=%d" % bad)
    return 0 if bad == 0 else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description="matrix producer/consumer 契约检查（三态退出码）")
    ap.add_argument("--selftest", action="store_true", help="四条形状配对 + producer 可读性")
    ap.add_argument("--explicit", default="integration_tests_minimal integration_tests_empty",
                    help="第二组显式请求的 suite（默认两腿都跑：默认选择 + 显式选择）")
    ap.add_argument("--producer", default="", help="改跑某份 selector 副本（做旧形状的红侧对照）")
    ap.add_argument("--workflow", default="", help="改读某份 workflow 副本")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    mode, detail = consumer(workflow=a.workflow or None)
    print("CONSUMER mode=%s expr=%s" % (mode, detail))
    if mode is None:
        print("SUMMARY: matrix-contract verdict=UNVERIFIED（消费点读不出来，不判通过也不判违规）")
        return 2
    worst = 0
    for label, args in (("default", []), ("explicit", a.explicit.split())):
        payload, err = produce(args, producer=a.producer or None)
        if payload is None:
            print("RUN %-8s producer 取不到：%s ⇒ UNVERIFIED" % (label, err))
            worst = max(worst, 2)
            continue
        rc, lines = judge(payload, mode)
        worst = max(worst, rc)
        print("RUN %-8s rc=%d" % (label, rc))
        for l in lines:
            print("        " + l)
    print("SUMMARY: matrix-contract verdict=%s" % ("PASS" if worst == 0 else ("VIOLATION" if worst == 1 else "NO-VERDICT")))
    return worst


if __name__ == "__main__":
    sys.exit(main())
