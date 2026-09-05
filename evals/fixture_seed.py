#!/usr/bin/env python3
"""evals/fixture_seed.py — the text edits fixtures.sh makes to a freshly
bootstrapped node, as a module rather than a heredoc.

Three subcommands:

  fill-contract    answers the contract placeholders node.sh deliberately
                   leaves for a human, so a fixture does not arrive with
                   REPAIR: flags and spend every eval session on repair
  route-sections   fills the Sections: cell of the architecture routing
                   table, which is how a sub-doc becomes reachable
  check-premises   verifies every claim a prompt makes about the built
                   tree ("the doc says X", "the field is misspelled Y")
                   is actually true of it, and fails the build if not

fill-contract and route-sections are exact, in-place rewrites: they take
the file path, edit what they were asked to edit, and touch nothing else.
Neither creates a file, so a rename upstream fails loudly here rather than
seeding a fixture that is quietly missing its trap.

check-premises is the fixture builder's own claims-to-checks pass: a
prompt's premises live beside it in spec.json, and are enforced at build
time so a drifted premise voids the run instead of quietly grading a
fiction the fixture no longer contains.

Full documentation: evals/README.md.

Usage: fixture_seed.py fill-contract <contract.md>
       fixture_seed.py route-sections <architecture.md> <sections>
       fixture_seed.py check-premises <spec.json> <fixture-name> <built-dir>
"""

import io
import json
import os
import re
import sys

USAGE = """Usage: fixture_seed.py fill-contract <contract.md>
       fixture_seed.py route-sections <architecture.md> <sections>
       fixture_seed.py check-premises <spec.json> <fixture-name> <built-dir>

fill-contract   replaces every "- <Key>: <placeholder>" line in the contract
                with the eval fixture's answer for that key. A key with no
                answer here becomes "n/a" rather than staying a placeholder,
                because a leftover placeholder is what status.sh flags.

route-sections  writes <sections> into the first empty "- **Sections:**"
                cell in the architecture routing table. That cell is the
                only thing making a sub-doc reachable, so a fixture whose
                trap is a routed doc depends on this edit landing.

check-premises  loads <spec.json>, takes the union of "premises" over every
                eval whose "fixture" equals <fixture-name>, and evaluates
                each against <built-dir>. Each premise has "path" (relative
                to <built-dir>) and exactly one of "contains" (a literal
                substring that must be present), "absent" (a literal
                substring that must not be present), or "exists": true (the
                path must exist). Any failure prints one line per failed
                premise and exits 2 — a prompt's premise about the fixture
                is enforced the same way the fixture's other traps are.
"""

# The answers a real operator would give during bootstrap, for the
# TypeScript service every fixture is built around.
CONTRACT_ANSWERS = {
    "Areas and package managers": "service `src/` — npm only",
    "Catalogs": "none yet",
    "Build": "none — `package.json` has no build script",
    "Test": "`npm test`",
    "Lint / typecheck": "none configured — `package.json` has no lint or typecheck script",
    "Generated files": "none",
    "Doc comments": "no surface requires them; the Comments rule applies with no exemption",
    "Project constraints": "no new runtime dependencies without asking",
}

PLACEHOLDER = re.compile(r"^- ([A-Za-z][^:]*): <[^>]*>$", re.M)
EMPTY_SECTIONS_CELL = "- **Sections:**\n"


def die(msg):
    sys.stderr.write("fixture_seed.py: %s\n" % msg)
    sys.exit(2)


def read(path):
    if not os.path.isfile(path):
        die("no such file: %s" % path)
    with io.open(path, encoding="utf-8") as fh:
        return fh.read()


def write(path, text):
    with io.open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def fill_contract(text, answers=None):
    """Answer every contract placeholder. Returns the rewritten text."""
    answers = CONTRACT_ANSWERS if answers is None else answers

    def sub(m):
        return "- %s: %s" % (m.group(1), answers.get(m.group(1), "n/a"))

    return PLACEHOLDER.sub(sub, text)


def route_sections(text, sections):
    """Fill the first empty Sections: cell. Returns the rewritten text."""
    if EMPTY_SECTIONS_CELL not in text:
        die("no empty %r cell to fill — the routing table's shape has changed"
            % EMPTY_SECTIONS_CELL.strip())
    return text.replace(EMPTY_SECTIONS_CELL,
                        "- **Sections:** %s\n" % sections, 1)


def load_premises(spec_path, fixture_name):
    """Union of "premises" over every eval whose "fixture" equals
    fixture_name, in spec order, duplicates kept — a duplicate premise is
    redundant, not wrong."""
    if not os.path.isfile(spec_path):
        die("no such file: %s" % spec_path)
    with io.open(spec_path, encoding="utf-8") as fh:
        try:
            spec = json.load(fh)
        except ValueError as exc:
            die("cannot parse %s: %s" % (spec_path, exc))
    premises = []
    for ev in spec.get("evals", []):
        if ev.get("fixture") != fixture_name:
            continue
        for p in ev.get("premises", []) or []:
            premises.append((ev.get("id", "?"), p))
    return premises


def check_premise(built_dir, premise):
    """Returns (ok, detail) for one premise against the built tree."""
    path = premise.get("path")
    if not path:
        return False, "premise has no \"path\": %r" % (premise,)
    full = os.path.join(built_dir, path)
    if "exists" in premise:
        ok = os.path.exists(full) == bool(premise["exists"])
        return ok, "%s exists=%s" % (path, os.path.exists(full))
    if not os.path.isfile(full):
        return False, "%s does not exist" % path
    with io.open(full, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    if "contains" in premise:
        needle = premise["contains"]
        return (needle in text), "%s does not contain %r" % (path, needle)
    if "absent" in premise:
        needle = premise["absent"]
        return (needle not in text), "%s contains %r, which the premise says is absent" % (path, needle)
    return False, "premise has none of contains/absent/exists: %r" % (premise,)


def cmd_check_premises(args):
    if len(args) != 3:
        die("check-premises takes <spec.json> <fixture-name> <built-dir>")
    spec_path, fixture_name, built_dir = args
    premises = load_premises(spec_path, fixture_name)
    failures = []
    for eval_id, premise in premises:
        ok, detail = check_premise(built_dir, premise)
        if not ok:
            failures.append("%s: premise failed for eval %s: %s" % (fixture_name, eval_id, detail))
    if failures:
        for line in failures:
            sys.stderr.write("fixture_seed.py: %s\n" % line)
        sys.exit(2)
    return 0


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.stdout.write(USAGE)
        return 0
    command, args = argv[0], argv[1:]

    if command == "fill-contract":
        if len(args) != 1:
            die("fill-contract takes exactly one path")
        path = args[0]
        write(path, fill_contract(read(path)))
    elif command == "route-sections":
        if len(args) != 2:
            die("route-sections takes a path and a sections string")
        path, sections = args
        write(path, route_sections(read(path), sections))
    elif command == "check-premises":
        return cmd_check_premises(args)
    else:
        die("unknown command: %s (see --help)" % command)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
