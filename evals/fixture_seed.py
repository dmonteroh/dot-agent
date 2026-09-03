#!/usr/bin/env python3
"""evals/fixture_seed.py — the text edits fixtures.sh makes to a freshly
bootstrapped node, as a module rather than a heredoc.

Two of them, both rewriting a file node.sh init has just written:

  fill-contract   answers the contract placeholders node.sh deliberately
                  leaves for a human, so a fixture does not arrive with
                  REPAIR: flags and spend every eval session on repair
  route-sections  fills the Sections: cell of the architecture routing
                  table, which is how a sub-doc becomes reachable

Both are exact, in-place rewrites: they take the file path, edit what they
were asked to edit, and touch nothing else. Neither creates a file, so a
rename upstream fails loudly here rather than seeding a fixture that is
quietly missing its trap.

Full documentation: evals/README.md.

Usage: fixture_seed.py fill-contract <contract.md>
       fixture_seed.py route-sections <architecture.md> <sections>
"""

import io
import os
import re
import sys

USAGE = """Usage: fixture_seed.py fill-contract <contract.md>
       fixture_seed.py route-sections <architecture.md> <sections>

fill-contract   replaces every "- <Key>: <placeholder>" line in the contract
                with the eval fixture's answer for that key. A key with no
                answer here becomes "n/a" rather than staying a placeholder,
                because a leftover placeholder is what status.sh flags.

route-sections  writes <sections> into the first empty "- **Sections:**"
                cell in the architecture routing table. That cell is the
                only thing making a sub-doc reachable, so a fixture whose
                trap is a routed doc depends on this edit landing.
"""

# The answers a real operator would give during bootstrap, for the
# TypeScript service every fixture is built around.
CONTRACT_ANSWERS = {
    "Areas and package managers": "service `src/` — npm only",
    "Catalogs": "none yet",
    "Build": "`npm run build`",
    "Test": "`npm test`",
    "Lint / typecheck": "`npm run lint`",
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
    else:
        die("unknown command: %s (see --help)" % command)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
