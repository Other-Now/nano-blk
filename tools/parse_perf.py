#!/usr/bin/env python3
"""Turn a perf-suite console log into results/perf-summary.{json,md} and
results/perf-profiles.txt.

usage: parse_perf.py results/raw/x86-perf-perf.log [outdir]
"""
import json
import os
import re
import statistics
import sys

log = open(sys.argv[1], encoding="utf-8", errors="replace").read().replace("\r", "")
out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(sys.argv[1]), "..")

runs = {}   # (dev, workload) -> list of dicts
for m in re.finditer(r"^NBFIO-BEGIN (\S+)\n(.*?)^NBFIO-END \1", log, re.S | re.M):
    label, body = m.group(1), m.group(2)
    dev, rep, wl = label.split("/")
    j = json.loads(body[body.index("{"):body.rindex("}") + 1])
    job = j["jobs"][0]
    side = job["write"] if job["write"]["io_bytes"] > job["read"]["io_bytes"] else job["read"]
    pct = side["clat_ns"].get("percentile", {})
    runs.setdefault((dev, wl), []).append({
        "iops": side["iops"],
        "bw_mib": side["bw_bytes"] / 2**20,
        "p50_us": pct.get("50.000000", 0) / 1000,
        "p99_us": pct.get("99.000000", 0) / 1000,
        "sys_cpu": job.get("sys_cpu", 0),
    })

devs = ["nano", "brd", "nullb_mem", "nullb"]
wls = ["first_write", "overwrite", "randread_qd1", "randwrite_qd1",
       "randread_qd32x4", "randwrite_qd32x4", "seqread_128k"]
summary = {}
for (dev, wl), rs in runs.items():
    summary.setdefault(dev, {})[wl] = {
        "n": len(rs),
        "iops_median": statistics.median(r["iops"] for r in rs),
        "iops_min": min(r["iops"] for r in rs),
        "iops_max": max(r["iops"] for r in rs),
        "bw_mib_median": statistics.median(r["bw_mib"] for r in rs),
        "p50_us_median": statistics.median(r["p50_us"] for r in rs),
        "p99_us_median": statistics.median(r["p99_us"] for r in rs),
    }
json.dump(summary, open(os.path.join(out, "perf-summary.json"), "w"), indent=1)

lines = ["| workload | " + " | ".join(devs) + " |", "|---|" + "---|" * len(devs)]
for wl in wls:
    cells = []
    for d in devs:
        s = summary.get(d, {}).get(wl)
        if not s:
            cells.append("n/a")
        elif wl == "seqread_128k":
            cells.append(f"{s['bw_mib_median']:,.0f} MiB/s")
        else:
            cells.append(f"{s['iops_min'] / 1000:,.0f}-{s['iops_max'] / 1000:,.0f}k "
                         f"(p99 {s['p99_us_median']:.1f} us)")
    lines.append(f"| {wl} | " + " | ".join(cells) + " |")
md = "\n".join(lines) + "\n"
open(os.path.join(out, "perf-summary.md"), "w").write(md)
print(md)

prof = re.findall(r"^NBPERF-BEGIN (\S+)\n(.*?)^NBPERF-END \1", log, re.S | re.M)
with open(os.path.join(out, "perf-profiles.txt"), "w") as fh:
    for label, body in prof:
        fh.write(f"== {label} ==\n{body}\n")
print(f"{len(prof)} perf profiles -> perf-profiles.txt")
