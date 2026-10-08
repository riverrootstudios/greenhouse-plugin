# RiverRoot Studios — Conventions & Standards

This reference is loaded by skills when they need to make tech stack, architecture, or quality decisions. It encodes RiverRoot Studios' institutional knowledge so AI-generated code matches what Dan or mb would write by hand.

---

## Tech Stack Defaults

| Layer | Default | Version | When to Deviate |
|-------|---------|---------|-----------------|
| Framework | Next.js (App Router) | 16 | Document in project CLAUDE.md |
| Runtime | Node.js | 22 LTS | Match Vercel runtime |
| UI Library | React | 19 | Follows Next.js |
| Database | Supabase (PostgreSQL + Auth + Realtime) | latest | Document in project CLAUDE.md |
| Payments | Stripe | latest | Only if client requires alternative |
| Styling | Tailwind CSS + shadcn/ui (Radix primitives) | 4 | Never for greenfield |
| State | Zustand (client), Server Components (server) | latest | Context API for truly local state only |
| Validation | Zod | latest | Never roll custom |
| Testing | Vitest + React Testing Library | latest | Playwright for E2E when needed |
| Email | Resend or Mailgun | latest | Project-specific choice |
| Hosting | Vercel | — | Document if different |
| Package Manager | pnpm | 9+ | Never npm or yarn |
| Analytics | PostHog | latest | Plus Vercel Analytics for Core Web Vitals |
| Language | TypeScript strict mode | 5.7+ | No `any`, strict null checks |

**Always use the latest stable release** of each dependency when scaffolding new projects. The versions above are minimums — prefer newer if available. When versions conflict, Next.js compatibility wins (it dictates React and Node.js versions).

---

## Architecture Patterns

### App Router Structure

```
app/
├── (public)/          # Landing, marketing, public pages
│   ├── page.tsx
│   └── layout.tsx
├── (auth)/            # Login, signup, password reset
│   ├── login/
│   ├── signup/
│   └── layout.tsx
├── (dashboard)/       # Authenticated app
│   ├── layout.tsx     # Auth check, sidebar, nav
│   ├── page.tsx       # Dashboard home
│   └── [feature]/
└── api/
    └── tenants/
        └── [tenantId]/
            └── [resource]/
                └── route.ts
```

### Multi-Tenant API

Nest all tenant-scoped resources under `tenants/[tenantId]/`. Every API route validates tenant membership before processing.

### Database Design (RLS-First)

- **Denormalize `tenant_id`** on every tenant-scoped table — RLS needs it on every row
- **RLS policies first**, then application queries. Never rely solely on application-level auth
- **Triggers for side effects** (audit logs, denormalized counts, cascading updates)
- **Typed queries from schema** — generate types from Supabase, never hand-type DB types
- **Migrations via Supabase CLI** in `supabase/migrations/`. Sequential, timestamped, reversible

### Frontend Patterns

- **Zustand with `skipHydration`** — avoids SSR hydration mismatches
- **Zod schemas for forms** — single source of truth for validation client and server
- **Server Components for data loading** — fetch in the component, no client-side useEffect for initial data
- **Server Actions for mutations** — co-located with the form, Zod-validated inputs
- **Supabase client pattern:**
  - `createServerClient` — server components, route handlers, Server Actions
  - `createBrowserClient` — client components only
  - Never mix. Never create ad-hoc clients

---

## Cost Philosophy

1. Free tiers first — Supabase free, Vercel free, PostHog free
2. Managed services over self-hosting — always
3. No premature optimization
4. PostgreSQL full-text search before Elasticsearch
5. Vercel Cron before a job queue
6. Simple before complex
7. Keep infrastructure stitchable — wrap third-party SDKs so you can swap them

---

## Quality Standards

### Linting & Formatting

- ESLint with Next.js Core Web Vitals rules
- Prettier: 2-space indent, double quotes, semicolons, trailing commas ES5
- Husky + lint-staged pre-commit hooks
- TypeScript strict mode: `noImplicitAny`, `strictNullChecks`, `strict: true`

### CI Pipeline

```bash
pnpm install --frozen-lockfile
pnpm lint
pnpm typecheck
pnpm test
pnpm build
```

Every PR must pass all steps. No exceptions.

---

## Testing Philosophy

### What to Test (Priority Order)

1. **Business logic** — validation rules, permission checks, data transformations, state machines
2. **API routes and Server Actions** — test the contract: given input, expect output
3. **Component behavior** — what the user sees and does, not internal state
4. **RLS policies** — multi-user test helpers, verify isolation
5. **Edge cases that have bitten before** — regression tests

### Patterns

- **Arrange-Act-Assert** — always
- **Factory functions over fixtures** — `makeUser()`, `makeTenant()`, `makeSubscription()`
- **Descriptive names as specifications** — `it("returns 403 when user is not a member of the tenant")`
- **Test isolation** — each test owns its state, no shared mutable state
- **One assertion per concept** — multiple assertions OK if they test the same thing

### What NOT to Test

- Don't chase coverage numbers — chase deployment confidence
- Don't test framework behavior (does Next.js route correctly?)
- Don't test implementation details (was `setState` called?)
- Don't test trivial getters/setters

---

## Security Defaults

- **Env vars**: Zod-validated at startup via `env.ts` parsing `process.env`
- **Dependencies**: `pnpm audit` in CI
- **Headers**: CSP, HSTS, X-Frame-Options, X-Content-Type-Options
- **Rate limiting**: Auth and public API routes (Vercel WAF or Upstash Ratelimit)
- **CORS**: Restricted to known origins. Never `*` in production
- **Secrets**: Vercel environment variables only. Never in code, never in `.env` committed to git

---

## Accessibility

- **Target**: WCAG 2.1 AA
- **Primitives**: shadcn/ui on Radix provides accessible components out of the box
- **Testing**: axe-core in component tests
- **Keyboard**: Full keyboard navigation, tested in E2E
- **Visual**: Visible focus indicators, skip-to-content link, semantic HTML, color contrast AA

---

## Observability

- **Analytics**: PostHog for product analytics, error tracking, session replay
- **Logging**: Structured JSON logging
- **Performance**: Core Web Vitals via Vercel Analytics
  - LCP < 2.5s
  - INP < 200ms
  - CLS < 0.1

---

## Deployment

| Environment | When | Database |
|-------------|------|----------|
| Preview | Every PR (Vercel auto-deploy) | Supabase branch DB |
| Production | Merge to main | Production Supabase |
| Staging | Add when there are paying users | Staging Supabase |

- Write reverse migrations for rollbacks
- Supabase branching for preview database isolation

---

## Decision Heuristics

### When to Split a Ticket

- Needs "and" to describe (unless both parts serve the same feature)
- Touches more than 5 files and they serve different concerns
- Scope grew during implementation
- Can't verify all changes in one review session

### When to Spike

- Can't estimate the work
- Unclear technical approach
- New integration or unfamiliar API
- Spikes produce knowledge, not production code

### When to Replan

- After every 3-5 tickets completed
- A ticket took significantly longer than estimated
- New dependency discovered
- Requirements changed

### Scope Creep Rules

See [work-breakdown.md](work-breakdown.md) for the scope creep decision table. Never silently expand scope.
