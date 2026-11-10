import json,sys,collections,glob
d=collections.defaultdict(list)
for f in glob.glob(sys.argv[1]+"/*.jsonl"):
    for line in open(f):
        o=json.loads(line)
        for rs in o.get("resourceSpans",[]):
            for ss in rs.get("scopeSpans",[]):
                for sp in ss.get("spans",[]):
                    d[sp["name"]].append((int(sp["endTimeUnixNano"])-int(sp["startTimeUnixNano"]))/1e6)
for k,v in sorted(d.items(), key=lambda kv:-sum(kv[1])):
    v.sort(); print(f"{k:55s} n={len(v):3d} p50={v[len(v)//2]:7.0f} total={sum(v):7.0f}")
