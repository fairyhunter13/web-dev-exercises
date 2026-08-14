# Developer Pre-Screening Test

[![CI](https://github.com/fairyhunter13/web-dev-exercises/actions/workflows/ci.yml/badge.svg)](https://github.com/fairyhunter13/web-dev-exercises/actions/workflows/ci.yml)
[![Deploy](https://github.com/fairyhunter13/web-dev-exercises/actions/workflows/deploy.yml/badge.svg)](https://github.com/fairyhunter13/web-dev-exercises/actions/workflows/deploy.yml)

Answers to a developer pre-screening test, by Hafiz Putra Ludyanto
(hafizputraludyanto@gmail.com), for the Full-Stack Developer (Golang + Vue.js) role.

## Start here: [ANSWERS.md](ANSWERS.md)

Live chat app: <https://d3irwxh641u3pi.cloudfront.net>. Open it in two windows. It is a demo
and comes down after the review, so [`docs/demo.gif`](docs/demo.gif) records the same thing.

Everything else here is the working behind it: every answer was run and its output captured
before it was written down.

## Layout

| Path | What is in it |
|---|---|
| [`ANSWERS.md`](ANSWERS.md) | Every question, in the document's order, chat app last |
| [`sql/`](sql) | The three queries, and a SQLite harness that runs them |
| [`js/`](js) | `titleCase`, word frequency, `delay`, the async/await rewrite, with tests |
| [`go/wordfreq/`](go/wordfreq) | The Go word-frequency answer, single-file and playground-ready |
| [`shared/`](shared) | One table of word-frequency cases, run by both the JS and Go suites |
| [`chat/`](chat) | The real-time chat app: Go WebSocket backend, Vue 3 + TypeScript frontend |
| [`infra/`](infra) | Terraform for the AWS deployment |
| [`scripts/`](scripts) | Helper scripts used by the commands below and by CI |
| [`.github/workflows/`](.github/workflows) | CI on every push, deploy to AWS on green `main` |
| [`docs/evidence/`](docs/evidence) | Screenshots of the SQL results, the Go playground run, and the chat app |
| [`docs/demo.gif`](docs/demo.gif) | The chat app running in two windows, recorded from the end-to-end suite |

## Running everything

```bash
# SQL — paste sql/*.sql into https://www.w3schools.com/sql/trysql.asp?filename=trysql_select_all
#   That emulator is Microsoft SQL Server, not MySQL. See ANSWERS.md.
./sql/test/run.sh          # the same queries against seeded SQLite

# JavaScript
cd js && npm install && npm test

# Go
cd go/wordfreq && go test ./... && go run .

# Chat app — backend and frontend, in two terminals
cd chat/backend  && go test -race ./... && go run ./cmd/localserver
cd chat/frontend && npm install && npm run test:unit && npm run test:e2e
cd chat/frontend && npm run build   # the bundle numbers under Evidence, below
cd chat/frontend && npm run dev
```

Then open <http://localhost:5173> in two windows, give each a different display name, and
type in one of them.

The end-to-end test starts both servers itself. It does need `npx playwright install chromium`
once. The same suite runs against the deployed stack:

```bash
cd chat/frontend
E2E_BASE_URL=https://d3irwxh641u3pi.cloudfront.net npx playwright test
```

To regenerate the evidence:

```bash
cd chat/frontend && npm run capture   # screenshots + one recording per window
cd ../.. && ./scripts/make-demo-gif.sh   # stitches them into docs/demo.gif (needs ffmpeg)
```

## How the chat app works

The protocol and the routing rules live in packages shared by both backends, so the version that
runs on AWS and the version a reviewer runs offline cannot drift apart.

Every frame carries a `type` discriminator, which the TypeScript side models as a discriminated
union. `parseOutbound()` then validates each frame at runtime before it is trusted. A socket is
untrusted input and `JSON.parse` returns `any`, so a type annotation on its own would document
the shape without checking it.

Validation is server-side. The browser's `maxlength` is a hint to the user, not a constraint on
the protocol. Lengths are counted in runes, so a cap expressed in bytes does not quietly give
someone writing in Indonesian a shorter message than someone writing in English.

Reconnection is required. API Gateway closes an idle WebSocket after 10 minutes and caps any
connection at 2 hours, and both are hard limits. The client reconnects with exponential backoff
and full jitter, and its first frame on every connection is `hello`, answered with the recent
transcript before anything else, so a reconnect rehydrates instead of starting blank. The jitter
matters once more than one window is open: without it, two clients dropped by the same server
restart reconnect in lockstep and keep colliding.

The client asks for the transcript, and the server does not volunteer it. That looks like a
wasted round trip until you try the other way. API Gateway does not consider a connection to
exist for the `@connections` API until `$connect` has returned, so a push from inside `$connect`
comes back 410 Gone. That 410 is indistinguishable from a dead peer, and it cost me a stack that
looked healthy while delivering nothing.

The heartbeat interval is 4 minutes, not 30 seconds. API Gateway bills WebSocket messages, and
browsers cannot send protocol-level ping frames from JavaScript, so keep-alive has to be an
application message, and a chatty one is the only part of this demo that could burn real credit.

The send is optimistic. The sender renders its own message immediately with a `clientId`, and the
server echo replaces that copy instead of appending a second one. The end-to-end test asserts
`toHaveCount(1)` to catch the duplicate that a broken reconciliation would produce.

### Why the socket layer is hand-written

VueUse's `useWebSocket` already gives you heartbeat, `autoReconnect` and cleanup on scope
dispose, and it is what I would reach for in production. It felt like the wrong thing to hand in
as an answer to a question *about* WebSockets, so `useChatSocket` is written directly: a
five-state machine (`connecting`, `open`, `reconnecting`, `closed`, `failed`) over the browser's
bare three, backoff with jitter, and teardown in `onScopeDispose`. One detail for anyone reaching
for VueUse today:
[`heartbeat.interval` is deprecated in favour of `scheduler`](https://vueuse.org/core/useWebSocket/),
as in `scheduler: cb => useIntervalFn(cb, 2000)`, and almost every tutorial still shows the old
form.

### Animation alternatives, and auto-scroll

Newer options were considered and not used.
[`@starting-style`](https://developer.mozilla.org/en-US/docs/Web/CSS/@starting-style)
(Baseline since August 2024) animates entry only, and what the question asks for is the
*reposition* of the existing messages. Same-document View Transitions
([Baseline Newly available 14 October 2025](https://web.dev/blog/same-document-view-transitions-are-now-baseline-newly-available))
do handle it, but they serialise, so a burst of messages queues up.

Auto-scroll measures `scrollHeight - scrollTop - clientHeight` before the DOM updates, with
`flush: 'pre'`, and only scrolls if the user was already at the bottom. Otherwise it shows a
"N new messages ↓" pill. The commonly suggested `flex-direction: column-reverse` is avoided,
because it inverts DOM order against visual order and breaks screen-reader reading order and Tab
order (WCAG 1.3.2 and 2.4.3). The list is a
`<ul role="log" aria-live="polite" aria-relevant="additions">`, polite rather than assertive, so
an incoming message queues behind whatever the user is doing instead of interrupting.

## Deploying the chat app

Requires an AWS account and a named profile (never the default profile).

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars   # set budget_email and aws_profile
./deploy.sh plan                               # review
./deploy.sh                                    # build, apply, upload, invalidate
```

The Lambda is cross-compiled for `linux/arm64`, and the frontend is built against the WebSocket
URL Terraform produces. Tear it down with `terraform destroy`. A Budgets alert watches actual
and forecast spend.

```
Browser (Vue 3 + TS) ──HTTPS──> CloudFront ──> S3 (private, OAC)
       │
       └──WSS──> API Gateway WebSocket ──> Go Lambda (arm64, provided.al2023)
                                              └──> DynamoDB (connections, messages)
```

### Traps this stack is commonly got wrong on

The code comments say so at each site. The first four came out of reading the current provider
and AWS documentation. The last two only appeared once it was applied, which is the argument for
deploying and not stopping at a clean `terraform validate`.

- DynamoDB is `PROVISIONED`, not on-demand. The free 25 read and write capacity units exist
  only under provisioned billing. On-demand gets the free storage and pays per request.
- The WebSocket API has an explicit `aws_apigatewayv2_deployment`. `auto_deploy` is
  HTTP-API-only. Without the explicit deployment, the API serves its original configuration and
  silently ignores every subsequent route change.
- The `execute-api:ManageConnections` resource hangs off the execution ARN, as
  `<stage>/POST/@connections/{connectionId}`, not `<api>/@connections/*`. What makes the short
  form wrong is the missing stage and method, not the `@connections` segment. The wrong form
  fails at runtime as a 403 that looks like a broken client. The policy in
  [`lambda.tf`](infra/lambda.tf) grants `execution_arn/*`, which covers that path; narrow it to
  the exact stage and method if you run more than one stage.
- CloudFront's origin is the S3 REST endpoint, not the website endpoint. OAC cannot sign to the
  website endpoint, and the website endpoint needs a public bucket, which is the thing OAC
  exists to avoid. 403 and 404 are mapped back to `/index.html` for the SPA.
- Access logging needs an account-level CloudWatch role before any stage can use it. On a
  brand-new account, creating the stage fails outright with *"CloudWatch Logs role ARN must be
  set in account settings"*. The setting is per account and region, and the only resource that
  writes it is `aws_api_gateway_account`, a v1-named resource that governs v2 APIs too. On an
  account where somebody set it years ago the requirement is invisible, which is why it rarely
  comes up.
- Nothing may be posted to a connection from inside `$connect`. API Gateway does not consider a
  connection to exist for the `@connections` management API until the `$connect` integration has
  returned, so pushing the transcript from there comes back 410 Gone. A 410 is also how a dead
  peer is reported, so the reaping logic deleted the registry row it had just written. The
  result was a stack where every layer looked healthy, messages were being written to DynamoDB,
  and Lambda logged no errors, because the handler really did succeed at broadcasting to an
  empty set. Only the API Gateway *access* log showed it, as a
  `POST /@connections/{connectionId}` with status 410 next to each `$connect`. The fix is a
  `hello` frame: `$connect` registers the connection and does nothing else, and the client asks
  for the transcript once the socket is open. The local server performs the same handshake on
  purpose, so the two transports cannot drift, and
  [`router_test.go`](chat/backend/internal/gateway/router_test.go) asserts that `Connect` posts
  nothing.

## What it costs

Nothing so far, and the working is below.

The account is on the AWS free plan. The billing docs put it plainly: "The Free account plan
ensures you won't incur any charges." If the credits run out or the plan ends, the account closes
instead of issuing a bill. `aws freetier get-account-plan-state` reports plan `FREE`, status
`ACTIVE`, and, as of 12 August 2026, $140 of credits left, ending 12 February 2027.

The risk is therefore spending the credit balance early and losing the account before you have
looked at the app. The limits in the Terraform are sized for that. DynamoDB is provisioned at 5
read and 5 write units per table, so both tables together sit inside the always free 25.
Point-in-time recovery is off, both tables expire rows with a TTL, and both log groups keep 7
days. The WebSocket stage is throttled to 5 requests a second with a burst of 10, which is more
than two browser windows need and small enough that a script pointed at the URL cannot get far. A
Budgets alert watches actual and forecast spend, though it can only tell you, it cannot stop
anything.

I wanted a reserved concurrency limit on the Lambda too, and AWS refused it: a new account has a
total concurrency limit of 10, and Lambda will not accept a reservation that leaves fewer than 10
unreserved. The account limit already does the same job. [`lambda.tf`](infra/lambda.tf) records
that, so the missing argument does not read as an oversight.

None of this is free forever. The free plan ends in February 2027 and takes the account with it,
so `terraform destroy` is what I will run once the review is done. That is also why the evidence
in this repository is recorded as committed files.

## Teardown

The demo does not need me to remember it. Two triggers, whichever comes first: the plan's expiry
date minus three days, or credits at or below $20. [`check-expiry.sh`](infra/check-expiry.sh) reads
both from `aws freetier get-account-plan-state` and runs [`teardown.sh`](infra/teardown.sh) when
either fires. [`teardown.yml`](.github/workflows/teardown.yml) calls it daily.

It is fail-closed, and that is the only interesting thing about it. An API error, an unparseable
date, an empty response and expired credentials all mean *not yet*; only a value that was parsed
and clearly satisfies a trigger destroys anything. A false negative costs a few days of uptime on
an account that is closing anyway. A false positive deletes a live demo while somebody is looking
at it.

Three days rather than one, because a scheduled workflow is documented as delayable and droppable
under load, and a destroy whose CloudFront stage alone takes 15 to 25 minutes deserves more than
one unattended attempt.

The order in `teardown.sh` is not cosmetic:

1. Build the Lambda binary. `data.archive_file` reads it, and a missing file fails during
   data-source evaluation, before anything is destroyed but also before anything is diagnosable.
2. **Archive, and refuse to continue unless it decrypts and parses.** No archive, no destroy.
3. Remove the OIDC provider and the CI roles from state, so Terraform cannot delete in its first
   parallel wave the credentials a retry would need.
4. `terraform destroy`, then sweep each service directly. A tag sweep alone would report clean
   with most of the stack standing: 13 state instances carry no tags, and IAM and Budgets are not
   covered by the tagging API at all.
5. Delete the identities last, the hand-made break-glass user last of all.

The archive is `age`-encrypted to a public recipient key, [committed beside the
script](infra/archive-recipient.pub). Encrypting needs no secret, so the key is safe to publish and
a machine that can write an archive still cannot read one. It holds the Terraform state, the
outputs, a per-service inventory and the account plan state — the record, which is what actually
dies with the account. Deliberately excluded: the `messages` table, which is whatever strangers
typed into a public demo and is better deleted than kept, and the log groups, which expire on their
own.

Nothing is committed and nothing is uploaded. [`deliver.sh`](infra/deliver.sh) writes a records-only
archive to local disk on a daily systemd timer with `Persistent=true`, so a laptop that was off
catches up rather than skipping. In CI the archive is a *gate* — proof the state was readable before
anything was destroyed — and it dies with the runner.

```sh
cd infra
./teardown.sh --dry-run     # every check, and a destroy plan, changing nothing
./check-expiry.sh --dry-run # report the decision without acting on it
./deliver.sh --install      # install the daily local archive timer
```

## Evidence

Everything below was run.

| Check | Command | Result |
|---|---|---|
| Backend logic | `go test -race ./...` | pass, race-clean |
| Backend coverage | `go test -cover ./...` | chat 98.0%, gateway 88.3%, awsstore 92.9% |
| Frontend units | `npm run test:unit` | 57 passed, 94.2% of statements |
| End-to-end, local | `npm run test:e2e` | 4 passed |
| End-to-end, deployed | `E2E_BASE_URL=https://d3irwxh641u3pi.cloudfront.net npx playwright test` | 4 passed |
| Types | `npm run type-check` (`vue-tsc --build`) | clean |
| Production build | `npm run build` | 75.80 kB JS, 30.01 kB gzipped |
| Infrastructure | `terraform fmt -check`, `terraform validate` | clean |

The unit test that matters most asserts the exact backoff schedule, `[500, 1000, 2000, 4000]` ms,
capped at 30 s. It is deterministic because the randomness is a parameter:
`backoffDelay(attempt, random)` takes the source as an argument, so pinning it to 1 asserts the
schedule, and pinning it to 0 and 0.5 asserts the jitter, with no timers involved. A second test
drives the reconnect *timing* with `vi.useFakeTimers()`, checking that nothing retries at 499 ms
and that exactly one socket has been opened at 500 ms, which is an off-by-one a "roughly half a
second" assertion would not catch.

The four end-to-end tests open two separate browser contexts, with separate storage, identity and
socket, which is the pattern Playwright documents. They cover four things. A message crosses from
one window to the other and back. Message order is correct geometrically, with the older bubble's
`y` above the newer one's, so a CSS regression that reversed the column cannot pass. A window
that joins late receives the transcript it missed. And the composer is disabled while the socket
is down. That last one intercepts the handshake with `page.routeWebSocket`. I tried the obvious
`context.setOffline(true)` first, and it is wrong: it blocks new requests but leaves an
established socket alive, so the test would pass against a client with no reconnect logic at all.

Writing the geometric assertion is what caught the one real bug in this app.
`<TransitionGroup tag="template">` looks like the way to avoid a wrapper element, but it renders
an actual `<template>` element, whose children are inert and never displayed, so no message
appeared at all. The text was in the DOM throughout, so an assertion on the text alone would have
passed.

## Continuous integration and deployment

[`ci.yml`](.github/workflows/ci.yml) runs every suite in the repository on every push and pull
request, with no credentials at all, and fails if coverage drops below 80%.
[`deploy.yml`](.github/workflows/deploy.yml) runs only after CI passes on `main`, and finishes
by running the end-to-end suite against the site it just deployed.

`ci.yml` also runs a job that pulls every fenced code block out of ANSWERS.md, runs it, and diffs
against the captured output beneath it. That is what keeps "paste it into a playground and it
runs" honest.

Two decisions behind that setup:

- **Terraform owns the infrastructure, Actions owns the code.** The state is local, so no
  workflow can safely run `apply`, and the deploy job only ships artefacts into resources that
  already exist. That leaves one problem: the Lambda would flip between whatever CI last
  published and whatever Terraform last saw, so `filename` and `source_code_hash` are under
  `ignore_changes`. Memory, timeout, runtime and environment are all still Terraform's, and all
  still show up in a plan.
- **No stored AWS keys.** The job presents GitHub's OIDC token and AWS exchanges it for
  credentials that expire with the job. The role in
  [`infra/github_oidc.tf`](infra/github_oidc.tf) is assumable only by the `production`
  environment of this one repository. The common shortcut, `repo:owner/*`, would let a workflow
  in any fork of a public repo assume the role, and the role's six permitted actions are scoped
  to four ARNs rather than to `*`.

That trust policy took two failed deploys to get right, and neither failure said anything more
than "Not authorized to perform sts:AssumeRoleWithWebIdentity". Declaring an `environment:` in a
job replaces `ref:refs/heads/main` in the token's `sub` claim rather than adding to it, and the
repository part of that claim is an immutable ID-based prefix, `repo:owner@<id>/repo@<id>`,
rather than the readable `owner/repo` that examples show. I ended up printing the claim from a
real token instead of guessing a third time.

Reproducing it on another account needs `terraform apply` and then five repository secrets,
taken from the Terraform outputs: `AWS_ROLE_ARN`, `SITE_BUCKET`, `DISTRIBUTION_ID`,
`LAMBDA_FUNCTION_NAME` and `VITE_WS_URL`. Secrets rather than variables, so resource names never
appear in a public build log.

## Versions

As of August 2026: Vue 3.5.41, Vite 8.2.1, TypeScript ~6.0, Vitest 4.1, Playwright 1.62,
Terraform ≥ 1.9 with AWS provider 6.x. The chat frontend pins exact versions; the four-file `js`
directory does not.

Neither Go module sets a `toolchain` directive. The `go` directives are the real floor each one
needs: `go/wordfreq` at 1.23, for `maps.Keys` and `slices.Sorted`, and `chat/backend` at 1.24,
the highest any dependency asks for. Development was on 1.26, and CI builds each module under
`GOTOOLCHAIN=local`, so a reviewer on an older toolchain can still build and test both.

TypeScript is held at 6.0, as `create-vue`'s template also does. TypeScript 7 ships no stable
programmatic compiler API, which `vue-tsc` needs, so template type-checking breaks under it and
`vue-tsc`'s peer range does not prevent the bad install. Vue is held at 3.5 for a similar
reason: 3.6 with Vapor Mode is feature-complete in RC but still needs package-manager-specific
version overrides.
