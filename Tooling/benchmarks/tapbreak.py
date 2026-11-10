import json, sys, collections
spans = []
for line in open(sys.argv[1]):
    d = json.loads(line)
    for rs in d["resourceSpans"]:
        for ss in rs["scopeSpans"]:
            spans.extend(ss["spans"])
by_id = {s["spanId"]: s for s in spans}
children = collections.defaultdict(list)
for s in spans:
    children[s.get("parentSpanId", "")].append(s)
def dur(s): return (int(s["endTimeUnixNano"]) - int(s["startTimeUnixNano"])) / 1e6
def attrs(s): return {a["key"]: list(a["value"].values())[0] for a in s.get("attributes", [])}
def tool(s): return attrs(s).get("amoo.tool.name") or attrs(s).get("gen_ai.tool.name")
roots = [s for s in spans if s["name"].startswith("execute_tool") or "tool" in s["name"]]
names = collections.Counter(s["name"] for s in spans)
print(names.most_common(40))

def desc(s):
    out = []
    for c in sorted(children[s["spanId"]], key=lambda x: int(x["startTimeUnixNano"])):
        out.append(c); out.extend(desc(c))
    return out
taps = sorted([s for s in spans if s["name"] == "execute_tool tap_element"], key=lambda x: int(x["startTimeUnixNano"]))
agg = collections.defaultdict(list)
for i, t in enumerate(taps[:int(sys.argv[2]) if len(sys.argv) > 2 else 4]):
    t0 = int(t["startTimeUnixNano"])
    print(f"--- tap_element #{i} total {dur(t):.0f}ms")
    for c in desc(t):
        print(f"  +{(int(c['startTimeUnixNano'])-t0)/1e6:6.0f}ms  {dur(c):6.0f}ms  {c['name']}")
for t in taps:
    for c in desc(t):
        agg[c["name"]].append(dur(c))
print()
n = len(taps)
tot = sum(dur(t) for t in taps)
print(f"{n} taps, mean total {tot/n:.0f}ms")
for k, v in sorted(agg.items(), key=lambda kv: -sum(kv[1])):
    print(f"{k:55s} calls/tap {len(v)/n:4.1f}  sum/tap {sum(v)/n:6.0f}ms  mean {sum(v)/len(v):5.0f}ms")
