#!/usr/bin/env python3
"""Read librarian.toml and print NAME=value lines, one per setting, for lib/common.sh to export.

  config.py FILE [--required]

A missing FILE prints nothing (exit 0), or with --required is an error (exit 2). The file is a flat
subset of TOML: `key = "string"`, `key = 'string'`, `key = 123`, `key = 1.5`, `key = true`, comments
and blank lines; a [section] header is not used and is refused. Lowercase keys are the documented
settings (KEYS below, mapped to the environment names the scripts read); an UPPERCASE key is passed
through under its own name, so any BRAIN_* tuning knob can be set here too. A value holding a
newline, an unknown lowercase key or a bad line is an error naming the line, never the value.
"""
import re
import sys

# documented key -> the environment name the scripts read (the older SWARM_BRAIN_*/BRAIN_* names
# are kept, so an environment that already sets them works unchanged)
KEYS = {
    "wiki_dir": "LIBRARIAN_WIKI_DIR",
    "collect_from": "LIBRARIAN_COLLECT_FROM",
    "host": "LIBRARIAN_HOST",
    "state_dir": "LIBRARIAN_STATE_DIR",
    "alert_cmd": "LIBRARIAN_ALERT_CMD",
    "gate_cmd": "LIBRARIAN_GATE_CMD",
    "budget_usd": "BRAIN_COST_CAP_USD",
    "lock_wait": "SWARM_BRAIN_LOCK_WAIT",
    "lock_poll": "SWARM_BRAIN_LOCK_POLL",
    "exclude": "BRAIN_EXCLUDE",
    "condense": "BRAIN_CONDENSE",
    "condense_model": "BRAIN_CONDENSE_MODEL",
    "ingest_model": "BRAIN_INGEST_MODEL",
    "local_model": "BRAIN_LOCAL_MODEL",
    "local_url": "BRAIN_LOCAL_URL",
}
LINE = re.compile(r"""^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$""")


def value(raw):
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
        v = raw[1:-1]
        if raw[0] == '"':
            if "\\" in v:
                v = bytes(v, "utf-8").decode("unicode_escape")
        return v
    raw = re.sub(r"\s+#.*$", "", raw)
    if re.fullmatch(r"-?[0-9]+(\.[0-9]+)?", raw) or raw in ("true", "false"):
        return raw
    raise ValueError("not a string, number or boolean")


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    path, required = argv[1], "--required" in argv[2:]
    try:
        text = open(path, encoding="utf-8").read()
    except FileNotFoundError:
        if required:
            print("librarian: config %s not found" % path, file=sys.stderr)
            sys.exit(2)
        return
    except OSError as e:
        print("librarian: cannot read config %s (%s)" % (path, e.__class__.__name__), file=sys.stderr)
        sys.exit(2)
    for n, line in enumerate(text.split("\n"), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        m = LINE.match(line)
        if not m:
            print("librarian: %s line %d: expected key = value" % (path, n), file=sys.stderr)
            sys.exit(2)
        key, raw = m.group(1), m.group(2)
        try:
            v = value(raw)
        except ValueError as e:
            print("librarian: %s line %d (%s): %s" % (path, n, key, e), file=sys.stderr)
            sys.exit(2)
        if "\n" in v or "\0" in v:
            print("librarian: %s line %d (%s): a value may not hold a newline" % (path, n, key), file=sys.stderr)
            sys.exit(2)
        if key.isupper():
            name = key
        elif key in KEYS:
            name = KEYS[key]
        else:
            print("librarian: %s line %d: unknown setting %s" % (path, n, key), file=sys.stderr)
            sys.exit(2)
        print("%s=%s" % (name, v))


if __name__ == "__main__":
    main(sys.argv)
