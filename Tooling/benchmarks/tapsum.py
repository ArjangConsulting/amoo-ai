import json, sys, collections
spans=[]
for line in open(sys.argv[1]):
    d=json.loads(line)
    for rs in d["resourceSpans"]:
        for ss in rs["scopeSpans"]: spans.extend(ss["spans"])
ch=collections.defaultdict(list)
for s in spans: ch[s.get("parentSpanId","")].append(s)
def dur(s): return (int(s["endTimeUnixNano"])-int(s["startTimeUnixNano"]))/1e6
def desc(s):
    o=[]
    for c in ch[s["spanId"]]: o.append(c); o.extend(desc(c))
    return o
taps=sorted([s for s in spans if s["name"]=="execute_tool tap_element"],key=lambda x:int(x["startTimeUnixNano"]))
for i,t in enumerate(taps):
    d=desc(t); c=collections.Counter(x["name"].split("/")[-1] for x in d)
    poll=sum(dur(x) for x in d if x["name"] in("screen_digest.read",)) + sum(dur(x) for x in d if x["name"]=="hierarchy.read")
    print(f"#{i:2d} {dur(t):6.0f}ms  Tap={sum(dur(x) for x in d if x['name'].endswith('/Tap')):4.0f}  "+" ".join(f"{k}x{v}" for k,v in c.items() if k not in("GetCurrentApp",)))
