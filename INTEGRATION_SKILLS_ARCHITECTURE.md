# Integration Skills Platform — Technical Architecture

> **Author:** Andrei Badescu
> **Date:** February 27, 2026
> **Status:** Proposal — pending CTO review

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Proposed Solution](#2-proposed-solution)
3. [Skill Taxonomy](#3-skill-taxonomy)
4. [Skill Design Principles](#4-skill-design-principles)
5. [Reference Apps](#5-reference-apps)
6. [Change Detection Pipeline](#6-change-detection-pipeline)
7. [Triage & Update Pipeline](#7-triage--update-pipeline)
8. [Change Intelligence Briefs](#8-change-intelligence-briefs)
9. [Full System Architecture](#9-full-system-architecture)
10. [Execution Plan](#10-execution-plan)
11. [Open Questions](#11-open-questions)

---

## 1. Problem Statement

### Context

Our product is an AI-powered app builder for the Romanian market. The most common user requests involve integrating with Romanian business infrastructure:

- **Government:** ANAF SPV (e-Factura, e-Transport), potentially ONRC
- **Invoicing SaaS:** SmartBill, Oblio, FGO
- **Banking:** BT, BCR, ING, Raiffeisen (PSD2/Open Banking APIs)
- **Logistics:** FAN Courier, Sameday, Cargus, DPD
- **Other:** Payments (Netopia, EuPlatesc), ERP systems

Our users are overwhelmingly non-technical. In a live demo with 70 course participants, an e-Factura integration was completed in 2 messages after providing Claude with a curated implementation guide. Without the guide, users struggle with undocumented pitfalls, inconsistent API behaviors, and Romanian-specific business logic that Claude doesn't inherently know.

### The Opportunity

If our system is "fluent" in these integrations out of the box, it becomes a major differentiator. No competing product (Lovable, Bolt.new, Base44) has domain-specific knowledge of Romanian business APIs. This fluency converts a multi-day developer task into a 2-message user interaction.

### The Challenge

- APIs change. ANAF is particularly bad about unannounced changes.
- Documentation quality varies wildly (government PDFs vs. proper REST docs).
- Business logic (invoice matching, reconciliation, e-transport declarations) is domain-specific and not something Claude knows natively.
- We need a system that stays current without constant manual intervention.

---

## 2. Proposed Solution

### Overview

Pre-install **curated integration skills** in the Claude Code instance that runs behind the scenes for each user. Each skill is a comprehensive, battle-tested implementation guide — not raw API docs — tailored to our product's stack (TypeScript, Node.js, Prisma ORM).

### Three Components

| Component | Purpose | Audience |
|---|---|---|
| **Integration Skills** | Curated guides that Claude loads when a user requests an integration. Contains architecture, full implementation code, pitfalls, and config. | Claude (injected into context) |
| **Reference Apps** | Working example implementations per integration. Used exclusively as test harnesses for the change detection pipeline. | Pipeline / CI (not Claude) |
| **Change Detection Pipeline** | Automated system that detects upstream API/doc changes and triggers skill updates. | Engineering team |

### Key Design Decision: Skills as the Single Source of Truth for Claude

The validated approach (proven in the e-Factura demo) is:

1. Research the API thoroughly (scrape docs, read community implementations, test against sandbox/production)
2. Distill that research into a curated implementation guide with inline code, architecture decisions, and pitfalls
3. Package the guide as a Claude Code skill
4. Claude reads the skill and can implement the full integration in 1-3 messages

Skills can be long. At ~1000 lines (~15-20K tokens), the e-Factura guide is well within the 200K context window. Even at 3-4x that size, a single skill consumes <15% of available context. Context pressure is minimal because:

- Only one integration is active at a time (users don't request ANAF + SmartBill + FAN Courier simultaneously)
- Conversations are short (user describes what they want → Claude builds it in 1-3 turns)
- The skill's detail is the value — more detail = fewer turns = better user experience

Reference apps exist solely for the pipeline's canary tests. Claude does **not** read from them at runtime.

---

## 3. Skill Taxonomy

Skills are organized at two levels:

### Level 1: Integration Skills (how to talk to a service)

Each skill covers CRUD operations and data sync for a single service. Contains:

- Authentication flow (OAuth2, API keys, certificates)
- Core API operations with full TypeScript implementation
- Data models (Prisma schemas, Zod validation, TypeScript interfaces)
- Rate limiting and pagination handling
- Error handling and retry logic
- Environment configuration
- Known pitfalls with solutions

**Examples:**

| Skill | Service | Core Functionality |
|---|---|---|
| `anaf-efactura-crud` | ANAF e-Factura | List, download, parse, store UBL/CII invoices |
| `anaf-etransport-crud` | ANAF e-Transport | Create, submit, track transport declarations |
| `smartbill-crud` | SmartBill | Sync invoices, estimates, receipts, stock |
| `oblio-crud` | Oblio | Sync invoices, proformas, notices |
| `bt-bank-statements` | Banca Transilvania | Fetch statements, parse transactions (PSD2) |
| `bcr-bank-statements` | BCR | Fetch statements, parse transactions (PSD2) |
| `fan-courier-crud` | FAN Courier | Create AWBs, track shipments, print labels |
| `sameday-crud` | Sameday | Create orders, track parcels, manage lockers |
| `netopia-payments` | Netopia | Payment initiation, webhooks, status tracking |

### Level 2: Feature/Workflow Skills (business logic that combines integrations)

These encode Romanian business workflows that combine multiple integrations. This is where the highest product value lives — these represent things users actually want to build.

**Examples:**

| Skill | Combines | Business Logic |
|---|---|---|
| `invoice-bank-matching` | ANAF e-Factura + Bank API | Match received invoices against bank transactions, track paid/unpaid status, flag discrepancies |
| `auto-reconciliation` | SmartBill/Oblio + Bank API | Reconcile issued invoices with incoming payments, update invoice status |
| `delivery-tracking-dashboard` | FAN/Sameday + Orders DB | Unified shipment tracking across multiple couriers, status webhooks |
| `e-transport-from-orders` | ANAF e-Transport + Orders/Inventory | Auto-generate transport declarations from sales orders |
| `payment-collection-flow` | Netopia + Invoicing SaaS | Send payment links for unpaid invoices, auto-mark as paid on webhook |

### Composition

Skills are composable. When a user says:

> "I want to pull my invoices from ANAF and match them with my BT bank statements to see what's been paid"

Claude loads:
1. `anaf-efactura-crud` — how to fetch and parse invoices
2. `bt-bank-statements` — how to fetch and parse bank transactions
3. `invoice-bank-matching` — how to match them and track payment status

Each skill is independently maintainable. An upstream change to BT's API only affects `bt-bank-statements`, not the matching logic.

---

## 4. Skill Design Principles

Based on the validated e-Factura guide (ANAF_SPV_INTEGRATION_GUIDE_V2.md), every skill should follow this structure:

### Required Sections

```
1. Overview
   - What the service is (1-2 paragraphs)
   - What the skill enables (bullet list of capabilities)

2. Prerequisites
   - Required credentials and how to obtain them
   - Stack requirements (aligned with our product: TS, Node, Prisma)
   - Environment variables template

3. Architecture
   - ASCII diagram showing data flow
   - Component responsibilities

4. Critical Implementation Notes
   - Numbered list of pitfalls with:
     - The problem (what goes wrong)
     - The symptom (what the user sees)
     - The fix (exact code)
     - Why it happens (so Claude understands the root cause)

5. Step-by-Step Implementation
   - Phased: Dependencies → Schema → Types → Services → Routes → Frontend
   - Full inline TypeScript code for every file
   - File paths specified for every code block

6. Configuration
   - All environment variables with descriptions
   - Defaults and valid ranges

7. Testing
   - Manual test script
   - Verification commands
```

### Principles

1. **Adapted to our stack.** All code uses TypeScript, our product's framework conventions, Prisma ORM, Zod validation, React Query on the frontend. Never generic — always specific to what the product's Claude instance will generate.

2. **Pitfalls-first.** The pitfalls section is the most valuable part. It prevents Claude from hitting the same walls that took hours to debug during research. Every non-obvious behavior gets documented.

3. **Inline code, not references.** Full implementation code lives directly in the skill. Claude should not need to fetch anything external at runtime.

4. **Opinionated defaults.** Don't present options — make decisions. "Use `adm-zip` with default import" not "you could use `adm-zip` or `jszip`." Reduce Claude's decision space.

5. **Tested against production.** Every skill must be validated against real API calls before shipping. The research phase includes building a working implementation, not just reading docs.

---

## 5. Reference Apps

### Purpose

Reference apps exist **exclusively** as test harnesses for the change detection pipeline. They are not a knowledge source for Claude.

### Structure

One repo (or monorepo) containing minimal working implementations per integration:

```
integration-test-harness/
├── anaf-efactura/
│   ├── src/
│   │   ├── client.ts          # Minimal API client
│   │   └── parser.ts          # XML parser
│   ├── tests/
│   │   ├── contract.test.ts   # Contract tests against real API
│   │   └── fixtures/          # Known-good response snapshots
│   ├── .env.example
│   └── package.json
├── smartbill/
│   ├── src/
│   │   └── client.ts
│   ├── tests/
│   │   └── contract.test.ts
│   └── ...
├── fan-courier/
│   └── ...
├── pipeline/
│   ├── doc-differ/            # Doc scraping & diffing
│   ├── canary-runner/         # Runs contract tests on schedule
│   ├── triage/                # Change classification & PR creation
│   └── change-intel/          # Change Intelligence brief generation
├── briefs/                    # Accumulated change intelligence archive
│   ├── 2026-02/
│   └── digest/
└── README.md
```

### Contract Tests

Each integration's contract tests assert the **API's behavioral contract** — the assumptions the corresponding skill relies on:

```typescript
// anaf-efactura/tests/contract.test.ts

describe('ANAF e-Factura API Contract', () => {
  it('listaMesajePaginatieFactura returns mesaje as array or object', async () => {
    const response = await client.get('/listaMesajePaginatieFactura', {
      params: { cif: TEST_CIF, startTime, endTime, pagina: 0 }
    });
    // The skill's normalizeMesaje() depends on this being array or object
    expect(
      Array.isArray(response.data.mesaje) ||
      typeof response.data.mesaje === 'object'
    ).toBe(true);
  });

  it('ZIP download contains XML file excluding semnatura', async () => {
    const zipBytes = await client.downloadZip(TEST_MESSAGE_ID);
    const zip = new AdmZip(zipBytes);
    const xmlEntries = zip.getEntries().filter(
      e => e.entryName.endsWith('.xml') && !e.entryName.includes('semnatura')
    );
    expect(xmlEntries.length).toBeGreaterThan(0);
  });

  it('UBL invoice contains expected top-level structure', async () => {
    // Validates the XML paths the skill's parser relies on
    const parsed = parser.parse(knownGoodXml);
    const invoice = parsed.Invoice || parsed['ubl:Invoice'];
    expect(invoice).toBeDefined();
    expect(invoice['cbc:ID']).toBeDefined();
    expect(invoice['cac:AccountingSupplierParty']).toBeDefined();
  });
});
```

These tests are the **canary in the coal mine**. When one fails, the skill's assumptions are broken and an update is needed.

---

## 6. Change Detection Pipeline

### Two Detection Layers

#### Layer 1: Document Diffing

Detects changes in upstream documentation (new endpoints, changed parameters, updated authentication flows, deprecated features).

**Implementation:**

- Use `changedetection.io` (self-hosted, open source) or a lightweight custom scraper
- Configure monitored URLs per integration:

```yaml
# pipeline/doc-differ/config.yaml
monitors:
  anaf-efactura:
    urls:
      - https://static.anaf.ro/static/10/Anaf/Informatii_R/API/
      - https://mfinante.gov.ro/web/efactura
    check_interval: 6h
    content_type: html
    skill_affected: anaf-efactura-crud

  anaf-efactura-pdf:
    urls:
      - https://static.anaf.ro/static/10/Anaf/Informatii_R/API/Oauth_procedura_inregistrare_aplicatii_portal_ANAF.pdf
    check_interval: 24h
    content_type: pdf
    skill_affected: anaf-efactura-crud

  smartbill:
    urls:
      - https://api.smartbill.ro/docs/
    check_interval: 12h
    content_type: html
    skill_affected: smartbill-crud

  fan-courier:
    urls:
      - https://www.selfawb.ro/api-reference
    check_interval: 24h
    content_type: html
    skill_affected: fan-courier-crud
```

**Process:**

1. Scraper runs on schedule, fetches each URL
2. Extracts text content (HTML → text, PDF → text)
3. Compares against stored previous snapshot (hash + full text diff)
4. If diff detected → stores new snapshot, emits `doc_change` event with:
   - Which integration
   - The raw diff
   - Which skill is affected

#### Layer 2: Canary Tests (Contract Testing)

Detects behavioral changes — the things doc scraping misses. This is the critical layer for Romanian government APIs that change without updating docs.

**Implementation:**

- GitHub Actions (or self-hosted runner) on a cron schedule
- Runs each integration's contract test suite against real APIs
- Uses sandbox environments where available, read-only production calls where not

```yaml
# .github/workflows/canary-tests.yml
name: Integration Canary Tests
on:
  schedule:
    - cron: '0 */6 * * *'  # Every 6 hours
  workflow_dispatch:

jobs:
  anaf-efactura:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: oven-sh/setup-bun@v2
      - run: cd anaf-efactura && bun install && bun test
    env:
      ANAF_TEST_TOKEN: ${{ secrets.ANAF_TEST_TOKEN }}
      ANAF_TEST_CIF: ${{ secrets.ANAF_TEST_CIF }}

  smartbill:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: oven-sh/setup-bun@v2
      - run: cd smartbill && bun install && bun test
    env:
      SMARTBILL_API_KEY: ${{ secrets.SMARTBILL_API_KEY }}

  # ... one job per integration
```

**On failure:**

1. Identifies which contract assertions broke
2. Maps to affected skill sections
3. Emits `contract_break` event with:
   - Which integration
   - Which tests failed
   - Failure details (expected vs actual)

#### Layer 1.5: Community Monitoring (Optional / Low Priority)

Monitor GitHub issues on key Romanian open-source repos for early warning signals.

**Repos to watch:**
- `anaf-oauth2` / `efactura` community projects
- SmartBill/Oblio SDK repos (if open source)
- Romanian dev forums (harder to automate, lower priority)

**Implementation:** A simple GitHub Actions workflow using `gh api` to poll recent issues on a list of repos, filter by keywords ("broke", "changed", "403", "deprecated"), and notify on Slack.

---

## 7. Triage & Update Pipeline

When a change is detected (from either layer), the triage pipeline processes it:

### Step 1: Classify the Change

```
doc_change event:
  → Parse the diff
  → Classify: new_endpoint | modified_endpoint | deprecated_endpoint |
               auth_change | rate_limit_change | doc_clarification | irrelevant

contract_break event:
  → Map failed assertions to skill sections
  → Classify: breaking_change | behavioral_change | transient_error
  → If transient (timeout, 503): retry 2x before escalating
```

### Step 2: Draft Skill Update (Claude Code SDK)

For non-transient, non-irrelevant changes:

```typescript
// pipeline/triage/draft-update.ts
import { Claude } from '@anthropic-ai/claude-agent-sdk';

async function draftSkillUpdate(change: DetectedChange) {
  const currentSkill = await fs.readFile(
    `skills/${change.skillAffected}.md`, 'utf-8'
  );

  const prompt = `
    You are updating an integration skill for our product.

    ## Current Skill
    ${currentSkill}

    ## Detected Change
    Type: ${change.type}
    Integration: ${change.integration}
    Details: ${change.details}
    ${change.diff ? `\n## Doc Diff\n${change.diff}` : ''}
    ${change.failedTests ? `\n## Failed Tests\n${change.failedTests}` : ''}

    ## Instructions
    1. Identify which sections of the skill are affected
    2. Draft the minimal update needed
    3. If a pitfall should be added, add it to Critical Implementation Notes
    4. Output the updated skill in full
  `;

  const updatedSkill = await claude.complete(prompt);
  return updatedSkill;
}
```

### Step 3: Open PR

```typescript
// pipeline/triage/open-pr.ts
async function openUpdatePR(change: DetectedChange, updatedSkill: string) {
  const branchName = `skill-update/${change.integration}-${Date.now()}`;

  await git.checkoutBranch(branchName);
  await fs.writeFile(`skills/${change.skillAffected}.md`, updatedSkill);
  await git.add(`skills/${change.skillAffected}.md`);
  await git.commit(`chore: update ${change.skillAffected} skill

Detected: ${change.type}
Source: ${change.source} (${change.source === 'canary' ? 'contract test failure' : 'doc diff'})
Details: ${change.summary}`);
  await git.push(branchName);

  await gh.createPR({
    title: `Update ${change.integration} skill — ${change.type}`,
    body: `
## Detected Change

**Source:** ${change.source === 'canary' ? 'Canary test failure' : 'Documentation diff'}
**Type:** ${change.type}
**Integration:** ${change.integration}

## Details

${change.details}

## Skill Diff

Claude drafted the following update. **Human review required.**

${change.source === 'canary' ? '⚠️ Contract tests are failing — this integration may be broken for users until merged.' : ''}
    `,
  });

  // Notify on Slack
  await slack.send(`🔄 Skill update PR opened for *${change.integration}*: ${prUrl}`);
}
```

### Step 4: Human Review & Merge

A developer:
1. Reviews the PR diff
2. If the change is behavioral: updates the contract tests to match the new behavior
3. If the reference app needs updating: updates it
4. Merges the PR
5. Skills repo is deployed → users' Claude instances pick up the update

---

## 8. Change Intelligence Briefs

### Purpose

Every detected change — whether a doc diff or a contract break — is also fed through a **Change Intelligence** step that generates a brief answering:

1. **What changed?** — Plain-language summary of the diff (not raw technical output)
2. **What's new?** — New capabilities that weren't available before (new endpoints, new fields, lifted restrictions)
3. **What broke or was deprecated?** — Capabilities that were removed or altered in a breaking way
4. **What does this mean for our users?** — Concrete use cases that are now possible, or existing features that need attention

### Why This Matters

The pipeline isn't just a maintenance tool — it's a **product intelligence system**. When SmartBill adds a new bulk export endpoint, we don't just want to update the skill. We want to know:

- Can we now build a "sync all invoices at once" feature that wasn't possible before?
- Does this unlock a new workflow skill worth creating?
- Is this something we should market? ("We support SmartBill's new bulk export — day one.")

This turns API monitoring from a cost center (keeping things from breaking) into a competitive advantage (knowing about new capabilities before anyone else).

### Implementation

The brief is generated as part of the triage pipeline, immediately after change classification:

```typescript
// pipeline/triage/change-intel.ts

interface ChangeBrief {
  integration: string;
  date: string;
  summary: string;
  newCapabilities: string[];
  breakingChanges: string[];
  userImpact: string;
  skillActionRequired: 'update_existing' | 'create_new' | 'none';
  marketingRelevant: boolean;
}

async function generateChangeBrief(change: DetectedChange): Promise<ChangeBrief> {
  const currentSkill = await fs.readFile(
    `skills/${change.skillAffected}.md`, 'utf-8'
  );

  const prompt = `
    You are an integration analyst for a Romanian AI app builder product.

    ## Context
    We monitor upstream APIs used by Romanian businesses. A change was detected.

    ## Current Skill (what our system knows today)
    ${currentSkill}

    ## Detected Change
    Type: ${change.type}
    Integration: ${change.integration}
    ${change.diff ? `\nDoc Diff:\n${change.diff}` : ''}
    ${change.failedTests ? `\nFailed Contract Tests:\n${change.failedTests}` : ''}

    ## Generate a Change Intelligence Brief
    Respond as JSON with these fields:
    - summary: 2-3 sentence plain-language summary of what changed
    - newCapabilities: Array of new things that are now possible
      (empty array if nothing new). Be specific about user-facing
      use cases, not just technical details.
    - breakingChanges: Array of things that broke or were deprecated
    - userImpact: 1-2 sentences on how this affects our users
    - skillActionRequired: "update_existing" if current skill needs
      changes, "create_new" if this warrants a new skill, "none" if
      informational only
    - marketingRelevant: true if this is something we could promote
      as a feature/advantage
  `;

  return await claude.complete(prompt);
}
```

### Output Channels

Briefs are delivered to four places:

1. **PR description** — Appended to the skill update PR so the reviewer has full context on why the change matters, not just what changed technically

2. **Internal Slack digest** — A weekly (or on-demand) digest posted to a dedicated `#integration-intel` channel:

```
📊 Integration Intelligence — Week of Feb 24, 2026

ANAF e-Factura:
  • No changes detected. All contract tests passing.

SmartBill:
  • NEW: Bulk invoice export endpoint added (/api/invoices/export-bulk)
  • Now possible: Users can sync entire invoice history in one call
    instead of paginating. Could reduce sync from minutes to seconds.
  • Action: Skill update PR opened (#142)
  • 🎯 Marketing relevant

FAN Courier:
  • BREAKING: AWB creation now requires "serviceType" field (was optional)
  • Action: Skill update PR opened (#143)
  • ⚠️ Existing user apps may break if they omit this field
```

3. **Internal changelog** — Accumulated into a structured log that tracks the evolution of each service's API over time. Useful for spotting trends (e.g., "ANAF has changed their auth flow 3 times in 6 months — we should add extra resilience").

4. **User-facing newsletter / in-app notifications** — When a brief has `marketingRelevant: true` and `newCapabilities` is non-empty, it feeds into the user-facing communication pipeline. The raw brief is transformed into user-friendly language:

   **Internal brief says:**
   > SmartBill added bulk invoice export endpoint (`/api/invoices/export-bulk`).
   > New capability: Users can now sync entire invoice history in a single call.
   > Skill updated to use bulk export for initial sync.

   **User-facing newsletter says:**
   > "You can now add a full invoice history sync to your dashboard — pull all your SmartBill invoices at once instead of waiting for them to trickle in. Just ask your app to sync invoices and it handles the rest."

   The user has no idea SmartBill changed their API. They just see a new capability appear. Behind the scenes: the doc differ caught the change → the skill was updated → the brief flagged it as marketing-relevant → the newsletter draft was generated.

   **Implementation:** The brief's `newCapabilities` and `userImpact` fields are fed to a separate Claude prompt that rewrites them for a non-technical audience. This draft goes into a `newsletter-drafts/` queue for the marketing/product team to review before publishing.

   ```
   briefs/
   ├── ...
   └── newsletter-drafts/
       ├── 2026-02-15-smartbill-bulk-sync.md    # Pending review
       ├── 2026-02-20-fan-courier-lockers.md    # Published
       └── ...
   ```

   This closes the loop: upstream change → detection → skill update → user-facing value announcement. The entire pipeline from API change to "here's what's new for you" can happen within a single review cycle.

```
briefs/
├── 2026-02/
│   ├── 2026-02-15-smartbill-bulk-export.json
│   ├── 2026-02-20-fan-courier-service-type.json
│   └── 2026-02-27-anaf-no-change.json
├── 2026-03/
│   └── ...
└── digest/
    ├── 2026-W09.md
    └── 2026-W10.md
```

### Triggering New Skill Creation

When a brief's `skillActionRequired` is `create_new`, the pipeline:

1. Opens a separate issue (not a PR) in the skills repo titled: `[New Skill Opportunity] {integration} — {capability}`
2. The issue body contains the brief's analysis of what's now possible
3. The team evaluates whether to prioritize building the new skill

This ensures new capabilities don't just get patched into existing skills — they get properly evaluated as potential new products/features.

---

## 9. Full System Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         UPSTREAM SERVICES                                │
│                                                                          │
│  ANAF    SmartBill    Oblio    BT/BCR    FAN    Sameday    Netopia      │
│  (SPV)                        (PSD2)    Courier                          │
└────┬─────────┬─────────┬────────┬────────┬────────┬──────────┬──────────┘
     │         │         │        │        │        │          │
     ▼         ▼         ▼        ▼        ▼        ▼          ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      CHANGE DETECTION LAYER                              │
│                                                                          │
│  ┌─────────────────────────┐    ┌─────────────────────────────────────┐ │
│  │     Doc Differ           │    │         Canary Tests                │ │
│  │                          │    │                                     │ │
│  │  • Scrapes doc URLs      │    │  • Contract tests per integration  │ │
│  │  • Extracts text/PDF     │    │  • Runs every 6h via CI            │ │
│  │  • Diffs against last    │    │  • Asserts behavioral contracts    │ │
│  │    known snapshot        │    │  • Catches silent API changes      │ │
│  │  • Emits doc_change      │    │  • Emits contract_break            │ │
│  │    events                │    │    events                          │ │
│  └────────────┬─────────────┘    └──────────────────┬──────────────────┘ │
│               │                                      │                   │
└───────────────┼──────────────────────────────────────┼───────────────────┘
                │                                      │
                ▼                                      ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                       TRIAGE PIPELINE                                    │
│                                                                          │
│  1. Classify change (breaking / behavioral / doc-only / irrelevant)     │
│  2. Map to affected skill(s)                                             │
│  3. Generate Change Intelligence Brief (what's new, what broke,          │
│     user impact, marketing relevance)                                    │
│  4. Claude (SDK) drafts minimal skill update                             │
│  5. Open PR in skills repo (brief included in PR description)            │
│  6. Notify team on Slack                                                 │
│  7. If new capability warrants new skill → open issue in skills repo     │
│                                                                          │
└───────────────┬──────────────────────────┬──────────────────────────────┘
                │                          │
                ▼                          ▼
┌────────────────────────────┐  ┌────────────────────────────────────────┐
│       HUMAN REVIEW         │  │      CHANGE INTELLIGENCE LOG           │
│                            │  │                                        │
│  Dev reviews PR → updates  │  │  • Internal Slack digest (weekly)      │
│  contract tests → merges   │  │  • Accumulated brief archive           │
│                            │  │  • New skill opportunity issues        │
│                            │  │  • User-facing newsletter drafts       │
│                            │  │    (marketing-relevant changes)        │
└─────────────┬──────────────┘  └───────────────────┬────────────────────┘
              │                                     │
              ▼                                     ▼
┌────────────────────────────┐  ┌────────────────────────────────────────┐
│     SKILLS REPOSITORY      │  │       USER NEWSLETTER / IN-APP         │
│     (skill updates)        │  │                                        │
│              │              │  │  "You can now add a full invoice       │
│              ▼              │  │   history sync to your dashboard..."   │
└────────────────────────────┘  └────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                       SKILLS REPOSITORY                                  │
│                                                                          │
│  skills/                                                                 │
│  ├── integration/                                                        │
│  │   ├── anaf-efactura-crud.md          (~1000-3000 lines each)         │
│  │   ├── anaf-etransport-crud.md                                        │
│  │   ├── smartbill-crud.md                                               │
│  │   ├── oblio-crud.md                                                   │
│  │   ├── bt-bank-statements.md                                           │
│  │   ├── bcr-bank-statements.md                                          │
│  │   ├── fan-courier-crud.md                                             │
│  │   ├── sameday-crud.md                                                 │
│  │   └── netopia-payments.md                                             │
│  └── workflows/                                                          │
│      ├── invoice-bank-matching.md                                        │
│      ├── auto-reconciliation.md                                          │
│      ├── delivery-tracking-dashboard.md                                  │
│      └── e-transport-from-orders.md                                      │
│                                                                          │
│  ───── deployed to ─────                                                 │
│                                                                          │
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                       PRODUCT (per-user Claude instance)                 │
│                                                                          │
│  ┌───────────────────────────────────────────────────────────┐          │
│  │  Claude Code Instance                                      │          │
│  │                                                             │          │
│  │  Pre-installed skills (from skills repo)                    │          │
│  │  → User: "integrate e-factura"                              │          │
│  │  → Skill loaded: anaf-efactura-crud.md                      │          │
│  │  → Claude implements full integration in 1-3 messages       │          │
│  │                                                             │          │
│  │  → User: "match invoices with bank statements"              │          │
│  │  → Skills loaded: anaf-efactura-crud.md                     │          │
│  │                    bt-bank-statements.md                     │          │
│  │                    invoice-bank-matching.md                  │          │
│  │  → Claude implements matching system in 2-4 messages        │          │
│  └───────────────────────────────────────────────────────────┘          │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 10. Execution Plan

### Phase 1: Foundation (Weeks 1-3)

**Goal:** Ship the first 3-5 integration skills for the most requested use cases.

| Task | Details |
|---|---|
| Identify top 5 integrations by user demand | Likely: ANAF e-Factura, SmartBill, Oblio, BT bank statements, FAN Courier |
| Research & build each integration | Same process as e-Factura: scrape docs → build working implementation → document pitfalls → distill into skill |
| Write integration skills | Follow the skill design principles and structure from Section 4 |
| Write 1-2 workflow skills | Start with invoice-bank-matching (highest value, most requested) |
| Deploy skills to product | Pre-install in Claude Code instances |
| Validate with real users | Recruit 5-10 users to test each integration, collect feedback |

**Deliverable:** Users can request the top 5 integrations and get working implementations in 1-3 messages.

### Phase 2: Test Harness (Weeks 3-5)

**Goal:** Build the reference apps and contract tests so we know when things break.

| Task | Details |
|---|---|
| Set up integration-test-harness repo | Monorepo structure from Section 5 |
| Write contract tests for each shipped integration | Extract key assertions from each skill's implementation |
| Configure CI (GitHub Actions) | Canary tests running every 6h |
| Set up alerting | Slack notifications on test failures |

**Deliverable:** Automated detection of upstream API behavioral changes.

### Phase 3: Doc Monitoring (Weeks 5-7)

**Goal:** Add documentation change detection.

| Task | Details |
|---|---|
| Deploy changedetection.io (or custom scraper) | Self-hosted, configured with all upstream doc URLs |
| Configure monitors per integration | URLs, check intervals, content types (see Section 6 config) |
| Build event bridge | Connect doc_change events to triage pipeline |

**Deliverable:** Automated detection of upstream documentation changes.

### Phase 4: Automated Triage + Change Intelligence (Weeks 7-10)

**Goal:** Build the pipeline that drafts skill updates and generates intelligence briefs automatically.

| Task | Details |
|---|---|
| Build triage classifier | Categorize changes by type and severity |
| Build Change Intelligence brief generator | Claude SDK generates structured briefs per detected change |
| Integrate Claude SDK for skill update drafting | Auto-draft skill updates from detected changes |
| Build PR automation | Auto-open PRs in skills repo with brief included in description |
| Internal Slack integration | `#integration-intel` channel with weekly digests |
| Newsletter draft pipeline | Marketing-relevant briefs auto-rewritten for non-technical users, queued for review |

**Deliverable:** When an upstream change is detected: (1) a PR with a drafted skill update appears for human review, (2) a brief explains what changed and why it matters, (3) if marketing-relevant, a user-facing newsletter draft is queued.

### Phase 5: Scale (Ongoing)

**Goal:** Expand to more integrations and workflow skills.

| Task | Details |
|---|---|
| Add integrations based on user demand | Each new integration follows the same process: research → build → skill → contract tests → doc monitors |
| Build more workflow skills | Identify common multi-integration patterns from user behavior |
| Optimize skill loading | Analyze which skills get composed together, optimize for common combinations |
| Refine newsletter pipeline | Track which newsletter items drive user engagement, feed that back into prioritization of new skills |

---

## 11. Open Questions

Items to discuss with CTO:

1. **Skill loading mechanism.** How exactly are skills loaded in our Claude Code instances today? Are they in `.claude/skills/`? Is there a registry? Do we need to modify the product to support skill composition (loading multiple skills for one request)?

2. **Credential management for canary tests.** Contract tests need real API credentials (ANAF tokens, SmartBill API keys, bank sandbox credentials). Where do we store these? Do we have test accounts for all target services?

3. **Skill deployment.** When a skill PR is merged, how does the update propagate to running user instances? Is it immediate (skill files pulled from a central repo) or does it require a product deployment?

4. **User-facing skill discovery.** Should users see a catalog of available integrations ("We support ANAF, SmartBill, FAN Courier...") or should it be invisible (Claude just knows)?

5. **Rate limiting on skill creation.** Each new integration requires ~1-2 weeks of research + testing by someone who understands the API. Who owns this work? Do we need to hire for it, or can existing team members handle it alongside other work?

6. **MCP as supplementary layer.** We decided skills are the primary delivery mechanism. Is there value in also exposing the raw curated docs via MCP for cases where Claude needs to look up a specific detail mid-implementation? Lower priority, but worth discussing.

7. **Versioning.** Should skills be versioned (e.g., `anaf-efactura-crud-v2.md`)? This matters if we need to support users who started building with an older version of a skill and shouldn't get breaking changes mid-build.

8. **Newsletter pipeline ownership.** The Change Intelligence briefs can auto-generate user-facing newsletter drafts for marketing-relevant changes. Who reviews and publishes these? Product team? Marketing? Do we need an approval workflow, or is it lightweight enough that one person can handle the queue? Does the product already have a newsletter / in-app notification system we can plug into?

---

*This document reflects the proposed architecture as discussed. Implementation details (especially around skill loading and deployment) depend on product internals to be clarified with the CTO.*