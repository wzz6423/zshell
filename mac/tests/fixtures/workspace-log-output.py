import sys

name = sys.argv[1]
print(f"1234567\tTAB-{name}", flush=True)
print(f"OLD-{name}-needle 组合 e\u0301", flush=True)
for index in range(120):
    print(f"filler {name} {index}", flush=True)
print(f"NEW-{name}-needle needle", flush=True)
for line in sys.stdin:
    print(f"INPUT-{name}-{line.strip()}", flush=True)
