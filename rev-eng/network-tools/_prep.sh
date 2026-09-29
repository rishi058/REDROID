C=dw-fast-api-lev06dh9n48stpefi8nkkmno-062345193190
sudo docker cp /tmp/_np_lelo_dual.py "$C":/tmp/_np_lelo_dual.py
echo "== extract bearer from capA flow2 =="
sudo docker exec "$C" python3 -c 'import json;d=json.load(open("/tmp/capA.json"));r=json.loads(d[2]["resp_body"]);open("/tmp/bearer.txt","w").write(r["access"]);print("bearer_len",len(r["access"]),"did",__import__("base64").urlsafe_b64decode(r["access"].split(".")[1]+"==")[:80])'
echo "== adb forward list (signer local ports -> 39026) =="
sudo docker exec "$C" adb forward --list
