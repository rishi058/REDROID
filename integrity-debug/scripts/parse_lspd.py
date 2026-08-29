import sqlite3, sys
db = sys.argv[1] if len(sys.argv) > 1 else "_lspd.db"
con = sqlite3.connect(db)
tables = [r[0] for r in con.execute("select name from sqlite_master where type='table'")]
print("TABLES:", tables)
for t in tables:
    try:
        rows = con.execute(f"select * from {t}").fetchall()
        cols = [d[0] for d in con.execute(f"select * from {t}").description]
    except Exception as e:
        print(f"-- {t}: {e}"); continue
    print(f"\n=== {t} ({len(rows)} rows) cols={cols} ===")
    for row in rows[:60]:
        print("   ", row)
