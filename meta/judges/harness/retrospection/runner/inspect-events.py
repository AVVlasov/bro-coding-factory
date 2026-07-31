"""Compact ralph events timeline."""
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: d = json.loads(line)
    except: continue
    t = d.get("event_type","?")
    i = d.get("iteration","?")
    p = d.get("payload",{}) or {}
    extra = ""
    if t == "verdict-recorded":
        extra = f' v={p.get("verdict")} crit={(p.get("failing_criterion") or "")[:60]} rem={p.get("remediation_count")}'
    elif t == "opencode-run":
        extra = f' dur={p.get("duration_sec",0):.0f}s exit={p.get("exit_code")} timeout={p.get("timed_out")}'
    elif t == "iter-completed":
        extra = f' bp={(p.get("bp_summary") or "")[:90]}'
    elif t == "loop-paused":
        extra = f' reason={p.get("reason")} {(p.get("error") or "")[:80]}'
    elif t == "tsc-failed":
        extra = f' exit={p.get("exit_code")}'
    print(f"{d.get('ts','')[:19]}  iter{i:>2}  {t:<24} {extra}")
