#!/usr/bin/env python3
"""Gate on the guest's "NB {json}" result lines.  Exit 1 on any failure.

usage: check_results.py results/<flavor>-<suite>.jsonl ...
"""
import json
import sys

failures = []


def need(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        failures.append(what)


def check(path, r):
    t = r.get("test")
    tag = f"{path}: {t}"
    if "error" in r:
        need(False, f"{tag} error={r['error']}")
    elif t == "kunit":
        need(r["fail"] == 0 and r["pass"] == 7, f"{tag} pass={r['pass']} fail={r['fail']}")
    elif t == "blkcheck":
        x = r["r"]
        need(x["mismatches"] == 0 and x["io_errors"] == 0,
             f"{tag} seed={r['seed']} ops={x['writes'] + x['reads'] + x['discards']} mismatches={x['mismatches']}")
    elif t == "fio_verify":
        need(r["rc"] == 0 and r["verify_errors"] == 0, f"{tag} rc={r['rc']}")
    elif t == "discard":
        need(r["pages_after_discard"] == 0 and r["reads_zero"], f"{tag} pages_after={r['pages_after_discard']}")
    elif t == "fault":
        f, a = r["fill"], r["after"]
        if f is None:
            need(False, f"{tag} blkcheck fill produced no result (rc={r['rc']})")
            return
        need(f["bad_blocks"] == 0, f"{tag} failed_writes={f['failed_writes']} bad_blocks={f['bad_blocks']}")
        need(r["driver_alloc_failures"] > 0, f"{tag} injection reached the driver ({r['driver_alloc_failures']})")
        need(a["mismatches"] == 0 and a["io_errors"] == 0, f"{tag} device healthy afterwards")
    elif t == "unload":
        need(r["splats"] == 0, f"{tag} splats={r['splats']}")
        need(r["kmemleak_after"] <= max(r["kmemleak_before"], 0),
             f"{tag} kmemleak before={r['kmemleak_before']} after={r['kmemleak_after']}")
    elif t in ("perf_done", "mem_done"):
        need(r["splats"] == 0, f"{tag} splats={r['splats']}")
    elif t == "oom":
        # Recorded, not gated: this is a measurement of behaviour (README).
        print(f"info {tag} dev={r['dev']} rc={r['dd_rc']} written={r['written_mib']} MiB "
              f"in {r['seconds']} s, oom_kills={r['oom_kills']} io_errors={r['io_errors']}")


for path in sys.argv[1:]:
    n = 0
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                need(False, f"{path}: malformed result line: {line[:120]}")
                continue
            check(path, r)
            n += 1
    if n == 0:
        need(False, f"{path}: no results")

sys.exit(1 if failures else 0)
