#!/usr/bin/env python3
"""evals/contamination.py — how much of the eval set has leaked into a corpus.

A corpus tuned against a fixed eval set can pass that set by carrying the
scenarios rather than the rules. Two probes, reported per corpus revision so
revisions can be compared side by side:

  lexical   shared word n-grams between the corpus's always-loaded text
            (preset, entry-point template, node.sh header contracts) and the
            eval material, split into scenario text (prompts, fixture seeds)
            and rule text (assertion claims, `expect` lines). Rule-text overlap
            is expected — the assertions test the corpus's own rules. Scenario
            overlap is the leak.
  judge     optional (--judge): one `claude --print` call that reads the eval
            prompts and the corpus and names corpus passages that describe
            the same situation as an eval prompt, whatever the vocabulary.
            Catches a scenario retold in an invented domain, which the
            lexical probe cannot. Uses the operator's logged-in CLI, like
            run.sh; never a provider API.

Usage: contamination.py [--spec <spec.json>] [--judge] [--model <m>] <ref>...

<ref> is a git revision of this repository (a branch, a tag, a sha), or
`dir:<path>` for a working tree. Prints one block per ref and a summary table.
"""

import io
import json
import os
import re
import subprocess
import sys
import tempfile

SELF = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SELF)

CORPUS_FILES = ("presets/software-development.md", "templates/entry-point.md", "scripts/node.sh")
FIXTURE_FILE = "evals/fixtures.sh"

STOP = set("""a an the and or of to in on for with by at from as is are was were be been being it its this
that these those there here into over under than then so if but not no nor do does did done have has had
having i you he she we they them their our your my me us him her which who whom whose what when where why
how all any each every some such only own same other another more most less least very just also can
could would should may might must will shall about above after again against before below between both
during few further once out up down off per via vs one two three""".split())

TOKEN = re.compile(r"[a-z0-9][a-z0-9_./:-]*")


def sh(args, cwd=ROOT, check=True):
    p = subprocess.run(args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if check and p.returncode != 0:
        sys.exit("contamination.py: %s failed: %s" % (" ".join(args), p.stderr.strip()))
    return p.stdout


def corpus_text(ref):
    if ref.startswith("dir:"):
        base = ref[4:]
        parts = []
        for f in CORPUS_FILES:
            with io.open(os.path.join(base, f), encoding="utf-8") as fh:
                parts.append(fh.read())
        return "\n".join(parts)
    parts = []
    for f in CORPUS_FILES:
        parts.append(sh(["git", "show", "%s:%s" % (ref, f)]))
    return "\n".join(parts)


def header_only(node_sh):
    """node.sh's shipped header contracts: the <!-- --> comments and the
    learned.md preamble, not the shell around them."""
    keep = []
    for line in node_sh.splitlines():
        if "<!--" in line or line.startswith("Binding rules") or line.startswith("Binding."):
            keep.append(line)
    return "\n".join(keep)


def tokens(text):
    text = text.lower().replace("`", " ")
    return [t.strip(".:,;") for t in TOKEN.findall(text)]


def ngrams(text, n):
    toks = [t for t in tokens(text) if t and t not in STOP]
    return set(tuple(toks[i:i + n]) for i in range(len(toks) - n + 1))


def eval_material(spec):
    scenario, rules = [], []
    for ev in spec["evals"]:
        scenario.append(ev.get("prompt", ""))
        rules.append(ev.get("expect", ""))
        for a in ev.get("assertions", []):
            rules.append(a.get("text", ""))
    with io.open(os.path.join(ROOT, FIXTURE_FILE), encoding="utf-8") as fh:
        fx = fh.read()
    # Fixture seeds: the heredoc bodies are the scenario content; the shell
    # around them is not.
    seeds = re.findall(r"<<'EOF'\n(.*?)\nEOF", fx, re.S)
    scenario.extend(seeds)
    return "\n".join(scenario), "\n".join(rules)


def lexical(corpus, scenario, rules):
    out = {}
    for label, text in (("scenario", scenario), ("rules", rules)):
        for n in (3, 4):
            shared = ngrams(corpus, n) & ngrams(text, n)
            out["%s_%dgram" % (label, n)] = sorted(" ".join(g) for g in shared)
    return out


JUDGE_PROMPT = """You are auditing an instruction corpus for contamination by an evaluation set.

Below are EVAL PROMPTS (each with an id) and a CORPUS. A corpus passage is CONTAMINATED when it describes the same situation as an eval prompt: the same kind of request, the same trap, and the same expected response, whether or not it uses the same words or domain. A passage that merely states the general rule an eval tests is NOT contaminated; a passage that walks through a concrete instance shaped like the eval is.

Return ONLY a JSON array. Each element: {"eval_id": "...", "corpus_quote": "<verbatim passage, at most 40 words>", "why": "<one sentence>"}. Return [] when nothing matches.

=== EVAL PROMPTS ===
%s

=== CORPUS ===
%s
"""


def judge(spec, corpus, model):
    prompts = "\n".join("[%s] %s" % (ev["id"], ev.get("prompt", "")) for ev in spec["evals"])
    body = JUDGE_PROMPT % (prompts, corpus)
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8") as fh:
        fh.write(body)
        path = fh.name
    args = ["claude", "--print", "--model", model, "--no-session-persistence",
            "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}', "--allowedTools", ""]
    try:
        with io.open(path, encoding="utf-8") as fh:
            p = subprocess.run(args, stdin=fh, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, cwd=tempfile.gettempdir())
    finally:
        os.unlink(path)
    if p.returncode != 0:
        return {"error": p.stderr.strip()[:500]}
    text = p.stdout.strip()
    m = re.search(r"\[.*\]", text, re.S)
    if not m:
        return {"error": "no JSON array in judge output", "raw": text[:500]}
    try:
        return json.loads(m.group(0))
    except ValueError:
        return {"error": "judge output is not JSON", "raw": text[:500]}


def main(argv):
    spec_path = os.path.join(SELF, "spec.json")
    use_judge = False
    model = "claude-sonnet-5"
    refs = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--spec":
            spec_path = argv[i + 1]; i += 2
        elif a == "--judge":
            use_judge = True; i += 1
        elif a == "--model":
            model = argv[i + 1]; i += 2
        elif a in ("-h", "--help"):
            print(__doc__); return 0
        else:
            refs.append(a); i += 1
    if not refs:
        print(__doc__); return 2
    with io.open(spec_path, encoding="utf-8") as fh:
        spec = json.load(fh)
    scenario, rules = eval_material(spec)
    summary = []
    for ref in refs:
        raw = corpus_text(ref)
        # node.sh contributes only its header contracts.
        preset_and_entry = "\n".join(raw.split("\n#!/usr/bin/env bash")[0:1])
        node_sh = sh(["git", "show", "%s:scripts/node.sh" % ref]) if not ref.startswith("dir:") else \
            io.open(os.path.join(ref[4:], "scripts/node.sh"), encoding="utf-8").read()
        corpus = preset_and_entry + "\n" + header_only(node_sh)
        lex = lexical(corpus, scenario, rules)
        words = len(corpus.split())
        row = {"ref": ref, "corpus_words": words,
               "scenario_3grams": len(lex["scenario_3gram"]), "scenario_4grams": len(lex["scenario_4gram"]),
               "rule_3grams": len(lex["rules_3gram"]), "rule_4grams": len(lex["rules_4gram"])}
        print("== %s (%d corpus words)" % (ref, words))
        print("   scenario overlap: %d 3-grams, %d 4-grams" % (row["scenario_3grams"], row["scenario_4grams"]))
        for g in lex["scenario_4gram"][:40]:
            print("     4: %s" % g)
        extra3 = [g for g in lex["scenario_3gram"] if not any(g in g4 for g4 in lex["scenario_4gram"])]
        for g in extra3[:40]:
            print("     3: %s" % g)
        print("   rule-text overlap (expected): %d 3-grams, %d 4-grams" % (row["rule_3grams"], row["rule_4grams"]))
        if use_judge:
            verdict = judge(spec, corpus, model)
            row["judge"] = verdict
            if isinstance(verdict, dict):
                print("   judge: ERROR %s" % verdict.get("error"))
            else:
                print("   judge: %d contaminated passage(s)" % len(verdict))
                for v in verdict:
                    print("     [%s] %s\n        -> %s" % (v.get("eval_id"), v.get("corpus_quote", "")[:200], v.get("why", "")))
        summary.append(row)
    print()
    print("%-28s %7s %8s %8s %8s %8s %6s" % ("ref", "words", "scen-3g", "scen-4g", "rule-3g", "rule-4g", "judge"))
    for r in summary:
        j = r.get("judge")
        jn = "-" if j is None else ("ERR" if isinstance(j, dict) else str(len(j)))
        print("%-28s %7d %8d %8d %8d %8d %6s" % (r["ref"][:28], r["corpus_words"], r["scenario_3grams"],
                                                 r["scenario_4grams"], r["rule_3grams"], r["rule_4grams"], jn))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
