"""Validate every JSON file of a PBIR report against the $schema it names (schemas fetched from Microsoft, cached)."""
import json, sys, urllib.request, hashlib
from pathlib import Path
from jsonschema import Draft7Validator, Draft202012Validator, validators
from referencing import Registry, Resource
from referencing.jsonschema import DRAFT7
from jsonschema_specifications import REGISTRY as META
CACHE = Path(__file__).parent / "schema_cache"; CACHE.mkdir(exist_ok=True)
def fetch(uri):
    if uri.startswith("http://json-schema.org/"):      # meta-schemas ship with jsonschema (json-schema.org answers 403)
        return META.contents(uri.rstrip("#"))
    f = CACHE / (hashlib.md5(uri.encode()).hexdigest() + ".json")
    if not f.exists():
        try:
            f.write_bytes(urllib.request.urlopen(uri, timeout=30).read())
        except Exception as e:
            raise RuntimeError(f"cannot fetch schema {uri}: {e}") from None
    return json.loads(f.read_text(encoding="utf-8-sig"))
def retrieve(uri):
    return Resource.from_contents(fetch(uri), default_specification=DRAFT7)
registry = Registry(retrieve=retrieve)
root = Path(sys.argv[1]); bad = 0; n = 0
for p in sorted(root.rglob("*.json")) + sorted(root.rglob("*.pbir")) + sorted(root.rglob("*.pbip")) + sorted(root.rglob("*.pbism")):
    # .pbi = Power BI Desktop's own local files (gitignored); its semanticModel localSettings 1.2.0 schema is a 404
    if {"StaticResources", ".pbi", "schema_cache"} & set(p.parts): continue
    doc = json.loads(p.read_text(encoding="utf-8")); sch = doc.get("$schema")
    if not sch: continue
    n += 1
    schema = fetch(sch)
    cls = validators.validator_for(schema, default=Draft7Validator)
    errs = list(cls(schema, registry=registry).iter_errors(doc))
    if errs:
        bad += 1
        print(f"\n{p.relative_to(root)}")
        for e in errs[:4]:
            print("   ", "/".join(map(str, e.absolute_path)), "->", e.message[:300])
print(f"\nchecked {n} files, {bad} with errors")
