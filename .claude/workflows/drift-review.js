export const meta = {
  name: 'drift-review',
  description: 'Deep-review a change set and its upstream/downstream neighbours against the process.md rubric, apply the mechanical fixes on a branch, and promote recurring findings into gates and rails',
  phases: [
    { title: 'Scope' },
    { title: 'Review' },
    { title: 'Verify' },
    { title: 'Apply' },
    { title: 'Rails' },
    { title: 'Report' },
  ],
}

// The runner (scripts/tools/drift-review.sh) computes the change set and hands it over, because
// a workflow script has no filesystem of its own — every git, grep and build action below runs
// inside an agent's Bash.
const A = args || {}
const REPO = A.repo || '/home/andrew/kudos'
const TREE = A.tree || REPO              // the worktree agents edit; never the user's checkout
const BRANCH = A.branch || 'drift/manual'
const BASE = A.base || 'HEAD~1'
const HEAD = A.head || 'HEAD'
const MODE = A.mode || 'commits'         // 'commits' | 'working-tree'
const SHAPE_PASS = A.shapePass === true  // the every-Nth-run whole-tree look
const LEDGER = `${REPO}/.claude/drift/findings.jsonl`

const VERIFY_BATCH = 6                   // cap the fan-out: N findings per adversarial verifier
const MAX_UNITS = 8                      // cap the review fan-out

// ── The lens ────────────────────────────────────────────────────────────────────────────────
// process.md's obligation ladder (§Blast-radius levels): obligations accumulate downward, so a
// K1 file is reviewed against everything a K3 file is, plus the real-time dimensions. Running
// all 56 criteria over every file is what makes a review slow and shallow at the same time.
// Which group sits at which level is layering.sh's klevel() map — the scope agent reads it
// there rather than from a copy here.
//
// The criteria themselves live in process.md and are cited BY NUMBER — never restated here.
// A paraphrase in this file would be a second home for the rubric, and the two would drift
// exactly the way CLAUDE.md says a copy always does.
const CRITERIA = {
  all: ['1-20', '49-56'],   // universal review + files & modularity
  K3: ['17', '48'],         // mutation-checked regressions; traces to a requirement
  K2: ['38', '39', '41'],   // budgeted hardware waits; designed overload; hostile-input suites
  K1: ['21-40'],            // the real-time dimensions in full
}

function criteriaFor(klevel) {
  const n = [...CRITERIA.all]
  if (klevel === 'K3' || klevel === 'K2' || klevel === 'K1') n.push(...CRITERIA.K3)
  if (klevel === 'K2' || klevel === 'K1') n.push(...CRITERIA.K2)
  if (klevel === 'K1') n.push(...CRITERIA.K1)
  return n.sort((a, b) => parseInt(a) - parseInt(b)).join(', ')
}

// process.md: "A review 'passes' a criterion only when a deliberate hunt for violations comes
// back empty, with file:line evidence." So a criterion that was never hunted must say so — a
// silent skip and a clean result are not the same claim.
const RUBRIC = `${REPO}/process.md, the section headed "The review rubric — 56 criteria".
Read it. Each criterion is a question you answer with evidence, not opinion.`

// ── What every agent needs to know about this repo ──────────────────────────────────────────
const CHARTER = `
You are reviewing kudos — a freestanding Zig x86-64 kernel with a GPU/compositor stack, USB,
networking and a hypervisor. The working copy for this run is ${TREE}. Read the actual files and
cite file:line for EVERY finding. Do not speculate; verify by reading.

THE STANDARD IS ALREADY WRITTEN. Do not invent doctrine:
 - ${REPO}/process.md — blast-radius levels K1-K4, the findings discipline, the 56-criteria rubric.
 - ${REPO}/CLAUDE.md — the rails. ${REPO}/.claude/rules/ — subsystem rails.
 - ${REPO}/specs/ — requirements as PREFIX-NNN identifiers; specs/README.md is the index.
Cite the criterion number or spec ID you are applying.

DO NOT RE-DERIVE WHAT A GATE ALREADY PROVES. \`bash ${TREE}/scripts/tests/layering.sh\` runs in
seconds with no build and is ground truth for: legal cross-group edges (GROUP_EDGES), declared
debt (EDGE_DEBT, GROUP_CYCLE_DEBT), named-module channels (MODULE_CHANNEL), which contracts a
loaded module may bind (IFACE_DISPOSITION), blast-radius levels (klevel), file size and
god-module allowlists, naming and test-pairing rules. Run it, read its output, and spend your
effort on the rubric criteria that have NO gate.

THE GRAPH LIES IN FOUR SPECIFIC WAYS (code-review-graph MCP):
 - detail_level "minimal" returns empty objects — always pass "standard".
 - get_impact_radius_tool at depth 2 returns most of the tree; use depth 1.
 - importers_of returns 0 for every src/iface/ contract, because contracts are imported BY NAME
   (@import("inet")) through build.zig's iface_mods and relative iface imports are banned. To
   find a contract's dependents: grep -rl '@import("<stem>")' ${TREE}/src/
 - get_affected_flows_tool returns 0 even for files on onKey/conSpawnApp/spawnBootLayout.

AND IT MAY NOT BE THERE AT ALL. This workflow is fired from a git hook, so it runs headless,
and an MCP server that authenticates interactively can simply be absent from that session. If
the code-review-graph tools are unavailable, say so in your output and fall back to grep — the
review still happens, with its reach stated honestly:
  callers of a function:   grep -rn '\\b<name>\\s*(' ${TREE}/src/
  dependents of a module:  grep -rl '@import(".*<stem>' ${TREE}/src/
  dependents of a contract: grep -rl '@import("<stem>")' ${TREE}/src/
Never silently review a file with no neighbours because a tool was missing — an unstated
narrowing of scope is the one failure this whole job exists to prevent.

Report only real, actionable findings. Quality over quantity. An empty list is a valid answer.
`

const FINDINGS_SCHEMA = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          line: { type: 'integer' },
          criterion: { type: 'string', description: 'The process.md rubric criterion (e.g. "§9") or spec ID this applies.' },
          klass: { type: 'string', description: 'Short kebab-case class of defect, e.g. "duplicated-constant", "history-comment", "unbounded-wait". Used to spot recurrence across runs.' },
          severity: { type: 'string', enum: ['high', 'medium', 'low'] },
          mechanical: { type: 'boolean', description: 'true only if the fix is mechanically verifiable and touches no design or interface: comment tightening, dead code, magic number naming, stale citation, naming violation.' },
          summary: { type: 'string', description: 'One sentence: the defect.' },
          evidence: { type: 'string', description: 'The offending text, quoted.' },
          invariant: { type: 'string', description: 'The property that must hold for this defect not to recur, stated where the owning code can carry it.' },
          fix: { type: 'string', description: 'The concrete change.' },
        },
        required: ['file', 'line', 'criterion', 'klass', 'severity', 'mechanical', 'summary', 'evidence', 'invariant', 'fix'],
      },
    },
    coverage: {
      type: 'array',
      description: 'One row per criterion you were assigned. A criterion with no findings must ' +
                   'still say whether you actually hunted for violations of it.',
      items: {
        type: 'object',
        properties: {
          criterion: { type: 'string', description: 'The number, e.g. "9".' },
          verdict: { type: 'string', enum: ['clean', 'findings', 'not-applicable', 'not-hunted'] },
          note: { type: 'string', description: 'For clean: what you looked at. For not-applicable or not-hunted: why.' },
        },
        required: ['criterion', 'verdict', 'note'],
      },
    },
  },
  required: ['findings', 'coverage'],
}

// ── Scope ───────────────────────────────────────────────────────────────────────────────────
phase('Scope')

const SCOPE_SCHEMA = {
  type: 'object',
  properties: {
    units: {
      type: 'array',
      description: 'Review units, one per source group that the change set touches. At most ' + MAX_UNITS + '.',
      items: {
        type: 'object',
        properties: {
          group: { type: 'string' },
          klevel: { type: 'string', enum: ['K1', 'K2', 'K3', 'K4'] },
          changed: { type: 'array', items: { type: 'string' }, description: 'Changed files in this group.' },
          neighbours: { type: 'array', items: { type: 'string' }, description: 'Upstream callers and downstream callees worth reading alongside them.' },
        },
        required: ['group', 'klevel', 'changed', 'neighbours'],
      },
    },
    gate: { type: 'string', description: 'Verbatim summary of layering.sh output: which checks failed, or "clean".' },
    notes: { type: 'string', description: 'Anything the reviewers must know: contract changes, new modules, near-limit files.' },
  },
  required: ['units', 'gate', 'notes'],
}

const scopeCmd = MODE === 'working-tree'
  ? `cd ${TREE} && git status --short && git diff --stat HEAD`
  : `cd ${TREE} && git diff --name-status ${BASE}..${HEAD} && git log --oneline ${BASE}..${HEAD}`

const scope = await agent(`${CHARTER}

SCOPE THIS REVIEW. Mode: ${MODE}.

1. Get the change set: \`${scopeCmd}\`
   (working-tree mode includes untracked files — list them with git status --short and include them.)
2. Run \`bash ${TREE}/scripts/tests/layering.sh\` and record which checks fail. This is the gate
   baseline: a check already failing before this change set is context, not a finding of ours.
3. Group the changed files by top-level src/ group and assign each group its blast-radius level
   from layering.sh's klevel() map (kernel/boot/iface=K1, drivers=K2, console/ui/widgets/apps/
   agent=K3; scripts/ and test/ are K4).
4. Expand each group with its UPSTREAM and DOWNSTREAM neighbours:
   - refresh the graph first: build_or_update_graph_tool (new files are invisible until it runs)
   - query_graph_tool callers_of / callees_of / tests_for, detail_level "standard"
   - get_impact_radius_tool at depth 1
   - for any changed file under src/iface/, the graph reports zero importers — use
     grep -rl '@import("<stem>")' ${TREE}/src/ instead. A changed contract is the highest
     blast-radius change class in this repo; do not under-scope it.
   Keep neighbours to the ones a reviewer must actually read — a list of 138 files is not a scope.
5. Emit at most ${MAX_UNITS} units. If more than ${MAX_UNITS} groups changed, merge the smallest.`,
  { label: 'scope', phase: 'Scope', schema: SCOPE_SCHEMA })

const units = (scope?.units || []).slice(0, MAX_UNITS)
log(`${units.length} review units; gate: ${scope?.gate || 'unknown'}`)

// ── Review ──────────────────────────────────────────────────────────────────────────────────
phase('Review')

const raw = await pipeline(
  units,
  u => agent(`${CHARTER}

YOUR UNIT: the \`${u.group}\` group, blast radius ${u.klevel}.

CHANGED FILES (the subject of the review):
${(u.changed || []).join('\n')}

NEIGHBOURS (read these to judge the changes in context — upstream callers and downstream
callees. A change is wrong when it breaks an assumption one of these makes, and that is
invisible if you only read the diff):
${(u.neighbours || []).join('\n') || '(none)'}

GATE BASELINE: ${scope?.gate || 'unknown'}
SCOPE NOTES: ${scope?.notes || '(none)'}

THE CRITERIA. Open ${RUBRIC}

At blast radius ${u.klevel}, obligations accumulate downward (process.md §Blast-radius levels),
so you are assigned criteria: ${criteriaFor(u.klevel)}

Read each of those criteria in process.md and apply it as written — do not work from memory of
what a criterion "probably" says, and do not apply criteria you were not assigned. A criterion
passes only when a deliberate hunt for violations comes back EMPTY. Return a coverage row for
every assigned criterion: "clean" means you hunted and found nothing, and you say what you
looked at; "not-hunted" is honest and useful, a silent skip dressed as clean is not.

For each finding state the INVARIANT — the property that must hold for the defect not to recur,
phrased so it could be written at the owning code. Mark \`mechanical: true\` ONLY when the fix is
verifiable without judgement and touches no design or interface: tightening a history-narrating
comment, deleting dead code, naming a magic number, correcting a stale citation, fixing a naming
violation. Anything that changes a signature, a contract, an ownership story or a control flow is
NOT mechanical.`,
    { label: `review:${u.group}`, phase: 'Review', schema: FINDINGS_SCHEMA }),
)

const all = raw.filter(Boolean).flatMap((r, i) =>
  (r.findings || []).map(f => ({ ...f, group: units[i]?.group, klevel: units[i]?.klevel })))

const coverage = raw.filter(Boolean).flatMap((r, i) =>
  (r.coverage || []).map(c => ({ ...c, group: units[i]?.group, klevel: units[i]?.klevel })))
const unhunted = coverage.filter(c => c.verdict === 'not-hunted')

log(`${all.length} raw findings across ${units.length} units` +
    (unhunted.length ? `; ${unhunted.length} assigned criteria went unhunted` : '; all assigned criteria hunted'))

// ── Verify ──────────────────────────────────────────────────────────────────────────────────
// Adversarial, but BATCHED. One agent per finding is unbounded fan-out: a 60-finding run used to
// mean 60 agents.
phase('Verify')

const VERDICTS_SCHEMA = {
  type: 'object',
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          index: { type: 'integer', description: 'The finding index given in the prompt.' },
          real: { type: 'boolean', description: 'true only if the finding is real AND worth acting on' },
          reason: { type: 'string' },
          revised_fix: { type: 'string' },
        },
        required: ['index', 'real', 'reason'],
      },
    },
  },
  required: ['verdicts'],
}

const batches = []
for (let i = 0; i < all.length; i += VERIFY_BATCH) batches.push(all.slice(i, i + VERIFY_BATCH))

const verdictBatches = await parallel(batches.map((b, bi) => () =>
  agent(`Try to REFUTE each of these code-review findings in ${TREE}. Read the actual files and
judge each one honestly and independently.

${b.map((f, i) => `--- index ${i}
file: ${f.file}:${f.line}
criterion: ${f.criterion}   class: ${f.klass}   severity: ${f.severity}
claim: ${f.summary}
evidence: ${f.evidence}
proposed fix: ${f.fix}`).join('\n')}

Refute a finding if ANY of these hold:
 - the quoted text does not exist, or is misquoted or out of date
 - the comment is EARNING its length: it states a non-obvious hardware or spec constraint
   concisely, and cutting it would lose a fact the next reader needs
 - the "defect" is a deliberate, correct design choice, or is already recorded as declared debt
   in layering.sh (EDGE_DEBT, GROUP_CYCLE_DEBT, the size or god-module allowlists)
 - the fix would lose load-bearing information or break something
 - it is trivial nitpicking not worth a change
 - the criterion cited does not say what the finding claims it says, or does not apply at this
   file's blast-radius level — check it against ${RUBRIC}

Confirm only what is real, specific and worth fixing. Default to refuting when uncertain.
Return one verdict per index, all ${b.length} of them.`,
    { label: `verify:batch-${bi + 1}`, phase: 'Verify', schema: VERDICTS_SCHEMA, effort: 'low' })
    .then(v => ({ base: bi * VERIFY_BATCH, v }))
))

const confirmed = []
for (const r of verdictBatches.filter(Boolean)) {
  for (const v of (r.v?.verdicts || [])) {
    const f = all[r.base + v.index]
    if (f && v.real) confirmed.push({ ...f, fix: v.revised_fix || f.fix })
  }
}
log(`${confirmed.length} of ${all.length} findings survived adversarial verification`)

// ── Apply ───────────────────────────────────────────────────────────────────────────────────
// Mechanical fixes only, in the worktree, gate-verified. The user's checkout is never touched.
phase('Apply')

const mechanical = confirmed.filter(f => f.mechanical)
const APPLY_SCHEMA = {
  type: 'object',
  properties: {
    applied: { type: 'array', items: { type: 'string' }, description: 'file:line of each fix actually applied.' },
    skipped: { type: 'array', items: { type: 'string' }, description: 'file:line plus the reason it was left alone.' },
    gate: { type: 'string', description: 'The exact result of make check-fast, including its exit code.' },
    committed: { type: 'boolean' },
  },
  required: ['applied', 'skipped', 'gate', 'committed'],
}

const apply = mechanical.length === 0
  ? { applied: [], skipped: [], gate: 'not run — no mechanical fixes', committed: false }
  : await agent(`Apply these confirmed MECHANICAL fixes in the worktree ${TREE}, on branch ${BRANCH}.

${JSON.stringify(mechanical, null, 2)}

Rules:
 - Work ONLY inside ${TREE}. Never touch ${REPO} — the user has uncommitted work there.
 - Apply only what is genuinely mechanical. If applying one turns out to need a judgement call,
   skip it and say why; it belongs in the report as a proposal instead.
 - Where a finding states an INVARIANT, write that invariant at the owning code as the comment.
   State the constraint, never the incident — no dates, no war stories, no "used to".
 - Then run: cd ${TREE} && make check-fast
   Capture the EXIT CODE and branch on it. Never grep the output for PASS — a grep succeeds on a
   red gate. If the exit code is non-zero, revert your edits (git checkout -- .) and report the
   failure; do not commit a red tree.
 - On success, commit with a message that names the defect and the criterion for each fix.`,
    { label: 'apply', phase: 'Apply', schema: APPLY_SCHEMA })

log(`applied ${apply?.applied?.length || 0}, skipped ${apply?.skipped?.length || 0}, gate: ${apply?.gate}`)

// ── Rails ───────────────────────────────────────────────────────────────────────────────────
// process.md §Gates: "an objective with no enforcing gate is debt". A finding class that keeps
// coming back is not a finding — it is a missing rail. This is the half that compounds.
phase('Rails')

const RAILS_SCHEMA = {
  type: 'object',
  properties: {
    recurring: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          klass: { type: 'string' },
          count: { type: 'integer' },
          action: { type: 'string', enum: ['gate', 'rail', 'none'] },
          where: { type: 'string', description: 'The file the rule now lives in.' },
          evidence: { type: 'string', description: 'The occurrences that earned it, file:line.' },
          proved: { type: 'string', description: 'For a gate: how it was proved RED before green.' },
        },
        required: ['klass', 'count', 'action', 'where', 'evidence'],
      },
    },
    shape: { type: 'string', description: 'The whole-tree shape observations, or "not this run".' },
  },
  required: ['recurring', 'shape'],
}

const rails = await agent(`You maintain the rails for kudos. Work in the worktree ${TREE} on branch ${BRANCH}.

THIS RUN'S CONFIRMED FINDINGS:
${JSON.stringify(confirmed.map(f => ({ klass: f.klass, criterion: f.criterion, file: f.file, line: f.line, summary: f.summary })), null, 2)}

1. Append every confirmed finding to ${LEDGER} as one JSON object per line:
   {"run":"${BRANCH}","klass":...,"criterion":...,"file":...,"group":...,"klevel":...}
   Create the file and its directory if absent.

2. Read the whole ledger. Count occurrences per \`klass\` ACROSS ALL RUNS.
   A class at **3 or more** occurrences is not a finding any more — it is a missing rail or a
   missing gate, and it gets retired as a class. For each such class:

   - MECHANICALLY CHECKABLE (a grep, find or awk can name every violation) → add a check to
     ${TREE}/scripts/tests/layering.sh. Follow that file's existing convention exactly:
       * a comment block above it saying WHY, citing the process.md criterion or spec ID
       * check "<name>" "<fix hint>" <command>   — any output from the command is a failure
       * if the rule needs an allowlist, one row per entry with a written reason, plus a
         companion "no stale rows" check so the allowlist cannot outlive what it excuses
     PROVE IT: demonstrate the check fails on an actual offending file before you make it pass
     (the project's seeded-RED-then-green rule). Record how you proved it.

   - NOT MECHANICALLY CHECKABLE → state the rule where it belongs: a subsystem rule under
     ${TREE}/.claude/rules/ if it applies to one part of the tree (with \`paths:\` frontmatter),
     or ${TREE}/CLAUDE.md if it is universal. Rails are rules and canonical homes only — never a
     list of instances. Keep CLAUDE.md under 200 lines.

   Classes under 3 occurrences: action "none". Do not pre-emptively add rails.

3. Then run \`cd ${TREE} && make check-fast\` and branch on its EXIT CODE, never on grepping for
   PASS. A new gate check must leave the tree green. If it does not, revert the gate change and
   report it rather than committing a red tree. Commit what passes.
${SHAPE_PASS ? `
4. WHOLE-TREE SHAPE PASS (this run only). Report — do not fix — on:
   - files approaching the 1000-line limit that are not on the size allowlist
     (\`find ${TREE}/src -name '*.zig' | xargs wc -l | sort -rn | head -20\`)
   - whether any EDGE_DEBT row or the apps<->ui cycle debt can now be paid off
   - the largest functions (find_large_functions_tool), which have no enforced rule
   - contracts under src/iface/ whose dependent count has grown enough to question the seam` : ''}`,
  { label: 'rails', phase: 'Rails', schema: RAILS_SCHEMA })

const promoted = (rails?.recurring || []).filter(r => r.action !== 'none')
log(`${promoted.length} finding classes promoted into gates or rails`)

// ── Report ──────────────────────────────────────────────────────────────────────────────────
phase('Report')

const report = await agent(`Write ${TREE}/REPORT.md — the drift review for ${BRANCH} (${MODE}, ${BASE}..${HEAD}).

CONFIRMED FINDINGS (each survived adversarial verification):
${JSON.stringify(confirmed, null, 2)}

CRITERION COVERAGE (which rubric criteria were actually hunted, per unit):
${JSON.stringify(coverage, null, 2)}

WHAT WAS APPLIED:
${JSON.stringify(apply, null, 2)}

RAILS AND GATES CHANGED:
${JSON.stringify(rails, null, 2)}

Structure it so a senior engineer can act on it directly:

1. **Verdict** — the single biggest pattern in this change set. Be blunt. If the change set is
   clean, say so in one line and stop; do not manufacture concern.
2. **Applied** — what was fixed on this branch, with the gate result and its exit code.
3. **Proposals** — confirmed findings that were NOT mechanical, so they need your judgement.
   For each: file:line, the criterion, the defect, the invariant, and the change you propose.
   Order by blast radius (K1 first), then severity.
4. **Rails changed** — every gate or rule this run added, with the recurrence evidence that
   earned it and how the gate was proved RED. This is the part to read most carefully: it
   changes the standard, not just the code.
5. **Coverage** — a compact table of criterion × unit from the coverage data: which criteria
   came back clean after a real hunt, and which went unhunted. process.md is explicit that a
   criterion passes only when a deliberate hunt comes back empty, so an unhunted criterion is
   an open question, not a pass. Name them; do not bury them.
6. **What NOT to change** — anything that looked like a defect but is a deliberate choice or
   already declared debt, so nobody "fixes" it later.
${SHAPE_PASS ? '7. **Shape** — the whole-tree observations from this run.\n' : ''}
Every item needs file:line and an actionable next step. No filler, no restating the brief.
Write the file, then return its path.`,
  { label: 'report', phase: 'Report' })

return {
  mode: MODE,
  branch: BRANCH,
  range: `${BASE}..${HEAD}`,
  units: units.length,
  raw: all.length,
  confirmed: confirmed.length,
  applied: apply?.applied?.length || 0,
  gate: apply?.gate,
  promoted,
  report,
}
