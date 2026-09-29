import json, sys
for path in sys.argv[1:]:
    print("===", path, "===")
    try:
        flows = json.load(open(path))
    except Exception as e:
        print("ERR", e); continue
    for i, x in enumerate(flows):
        body = (x.get("resp_body") or "").replace("\n", " ")[:100]
        print(i, x.get("status"), x["request"]["path"][:55], "|", body)
