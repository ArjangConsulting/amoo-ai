import json,sys,collections,glob
def load(dir):
    d=collections.defaultdict(list)
    for f in glob.glob(dir+"/*.jsonl"):
        for line in open(f):
            o=json.loads(line)
            for rs in o.get("resourceSpans",[]):
                for ss in rs.get("scopeSpans",[]):
                    for sp in ss.get("spans",[]):
                        d[sp["name"]].append((int(sp["endTimeUnixNano"])-int(sp["startTimeUnixNano"]))/1e6)
    return d
def p(v,q): v=sorted(v); return v[min(len(v)-1,int(q*len(v)))] if v else float('nan')
a,b=load("bench-base/telemetry"),load("bench-new/telemetry")
names=[n for n in ["execute_tool tap_element","execute_tool swipe","execute_tool long_press","execute_tool assert_visible","execute_tool find_elements",
 "hierarchy.read","amoo.v1.CompanionService/GetViewHierarchy","screen_digest.read","amoo.v1.CompanionService/GetScreenDigest",
 "amoo.v1.CompanionService/Tap","amoo.v1.CompanionService/Swipe","amoo.v1.CompanionService/LongPress","amoo.v1.CompanionService/FindElements","amoo flow"]]
print(f"{'span':45s} {'base n':>6s} {'p50':>6s} {'p95':>6s} {'total s':>7s} | {'new n':>5s} {'p50':>6s} {'p95':>6s} {'total s':>7s} | p50 Δ")
for n in names:
    x,y=a.get(n,[]),b.get(n,[])
    def f(v): return (f"{len(v):6d} {p(v,.5):6.0f} {p(v,.95):6.0f} {sum(v)/1000:7.1f}" if v else f"{0:6d} {'-':>6s} {'-':>6s} {'-':>7s}")
    d=(f"{(p(y,.5)-p(x,.5))/p(x,.5)*100:+.0f}%" if x and y else "")
    print(f"{n.replace('amoo.v1.CompanionService/','rpc '):45s} {f(x)} | {f(y)[1:]} | {d}")
