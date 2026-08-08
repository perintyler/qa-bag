---
name: qa
description: Run QA across a project - discover QA.md checklists, execute each via parallel subagents, aggregate verdicts into a report
allowed-tools: Task, Bash, Read, Glob, Grep, Write
args:
  - name: module
    description: Run QA for a single module path only (e.g. packages/db)
    required: false
  - name: strict
    description: Fail the overall run if any module-like directory lacks a QA.md
    required: false
  - name: filter
    description: Only run modules whose path contains this substring (e.g. mcp)
    required: false
---

# QA Runner

Discover every `QA.md` in the project, execute each one via a parallel subagent, and aggregate the verdicts into a single PASS/FAIL report. This is the preferred orchestration path — it replaces the bash pipeline in `packages/qa-guidelines/agent/` (which shells out to `claude --print` per module).

## Step 1: Discover

Find all QA.md files from the project root:

```bash
git rev-parse --show-toplevel   # project root
find . -name "QA.md" -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/dist/*" -not -path "*/build/*" -not -path "*/.qa-reports/*"
```

Then filter the results:

- **`.qaignore`** — if a `.qaignore` file exists at the project root, drop any QA.md whose path falls under a listed directory pattern (one pattern per line, `#` starts a comment).
- **`--module=PATH`** — keep only the QA.md at that path.
- **`--filter=STR`** — keep only paths containing STR.

Each surviving QA.md defines a module: name = its directory name, dir = its directory.

If `--strict` was passed, also find module-like directories missing a QA.md (dirs within depth 3 containing `package.json`, `Makefile`, `Cargo.toml`, `go.mod`, `pyproject.toml`, or `CMakeLists.txt`, minus ignored paths). These count against the overall verdict in strict mode; otherwise they are only listed in the report.

## Step 2: Run modules in parallel

Spawn one Task subagent per module, **all in a single message** so they run concurrently. Respect the module's `<!-- tools: ... -->` comment when deciding what the subagent should do (default assumption: Bash and Read only). Prompt for each subagent:

```
You are a QA runner. Execute the QA checklist for the module "<name>".

QA file: <dir>/QA.md
Working directory: <dir>

Instructions:
1. Read the QA file.
2. Run any Setup commands from the module directory.
3. Execute each numbered Test Step's exact command. Compare actual behavior
   against the step's **Expected:** line. Record PASS/FAIL/SKIPPED per step.
   Steps under an "Online checks" section whose external dependency is
   unavailable are SKIPPED, not FAILED.
4. Evaluate each Success Criteria item against what you observed.
5. Run Cleanup commands even if steps failed.
6. Verdict: PASS only if every non-skipped step matched Expected and every
   success criterion is satisfied. Otherwise FAIL. If you could not execute
   the checklist at all, ERROR.

Return ONLY this markdown, nothing else:

## <name>: PASS|FAIL|ERROR

### Analysis
2-4 sentences: what was verified, what failed and why, or what was skipped.

### Results
| Step | Status | Details |
|------|--------|---------|
...one row per test step...

### Success Criteria
- [x] met criterion
- [ ] unmet criterion
```

## Step 3: Aggregate

Parse each subagent's first heading (`## <name>: VERDICT`):

- Any ERROR → overall **ERROR**
- else any FAIL → overall **FAIL**
- else → overall **PASS**
- Strict mode: modules missing QA.md also force **FAIL**

## Step 4: Report

Write the report to `.qa-reports/report-<UTC yyyy-mm-dd-hhmmss>-<branch>.md` at the project root (create `.qa-reports/` if needed; it is excluded from discovery so reports are never QA'd, and should be gitignored):

```markdown
# QA Report: <timestamp>-<branch>

**<OVERALL VERDICT>**

| | |
|---|---|
| Generated | <UTC timestamp> |
| Branch | <branch> |
| Commit | <short sha> |
| Modules | N passed, N failed, N errored |

## Analysis

<Short synthesis. List every unmet success criterion as "module: criterion".>

---

<each module's returned markdown, verbatim, in discovery order>

## Modules Missing QA

- <path> (omit section if none)
```

Finally, tell the user the overall verdict, the per-module tallies, any unmet criteria, and the report path. Do not paste the whole report into the conversation.
