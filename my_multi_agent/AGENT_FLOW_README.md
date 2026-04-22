# my_multi_agent agent-flow README

This document explains how the multi-agent interaction flow is implemented and
which ADK settings control transfer, locking, sequential execution, and
parallel execution.

## 1. Design principle: single responsibility

Each agent has exactly **one job**:

| Agent | Type | Single responsibility | Tools |
|---|---|---|---|
| `root_agent` | **LlmAgent** | Greet user, delegate to validation_agent | _(none)_ |
| `validation_agent` | **LlmAgent** | Validate route + date, route to search pipeline or follow-up | `get_current_date`, `validate_departure_date`, `validate_route`, `show_supported_routes` |
| `flight_search_and_summary_agent` | **SequentialAgent** | Run search then summary in strict order | _(workflow — no tools)_ |
| `parallel_flight_search_agent` | **ParallelAgent** | Run both airline searches concurrently | _(workflow — no tools)_ |
| `airline_a_flight_search_agent` | **LlmAgent** | Query SkyPoland Airlines flights | `search_airline_a_flights` |
| `airline_b_flight_search_agent` | **LlmAgent** | Query PolAir Express flights | `search_airline_b_flights` |
| `summary_agent` | **LlmAgent** | Present combined results table after search | _(none)_ |
| `booking_agent` | **LlmAgent** | Handle booking selection/confirmation follow-ups | `book_flight` |

## 2. Agent graph with tools and types

```
root_agent (LlmAgent: flight_search_orchestrator, gemini-2.5-flash)
│   tools: (none)
│   sub_agents: [validation_agent]
│
└── validation_agent (LlmAgent, gemini-2.5-flash)
    │   tools: get_current_date, validate_departure_date,
    │          validate_route, show_supported_routes
    │   before_agent_callback: _before_validation_agent
    │   disallow_transfer_to_parent: True
    │   sub_agents: [flight_search_and_summary_agent, booking_agent]
    │
    ├── flight_search_and_summary_agent (SequentialAgent)
    │   │   ← strict order: step 1 completes before step 2 starts
    │   │
    │   ├── step 1: parallel_flight_search_agent (ParallelAgent)
    │   │   │   ← runs both airlines concurrently, waits for both to finish
    │   │   │
    │   │   ├── airline_a_flight_search_agent (LlmAgent, gemini-2.5-flash)
    │   │   │       tools: [search_airline_a_flights]
    │   │   │       disallow_transfer_to_parent: True
    │   │   │       disallow_transfer_to_peers: True
    │   │   │
    │   │   └── airline_b_flight_search_agent (LlmAgent, gemini-2.5-flash)
    │   │           tools: [search_airline_b_flights]
    │   │           disallow_transfer_to_parent: True
    │   │           disallow_transfer_to_peers: True
    │   │
    │   └── step 2: summary_agent (LlmAgent, gemini-2.5-flash)
    │           tools: (none)
    │           disallow_transfer_to_parent: True
    │           disallow_transfer_to_peers: True
    │
    └── booking_agent (LlmAgent, gemini-2.5-flash)
            tools: [book_flight]
            disallow_transfer_to_parent: True
            disallow_transfer_to_peers: True
            ← peer of flight_search_and_summary_agent; handles "book #1" / "yes" / "no"
```

## 3. Why a flat agent structure is not possible

An intuitive first design would be a flat tree where `root_agent` directly
orchestrates four peer sub-agents:

```
root_agent (LlmAgent)                    ← DOES NOT WORK
├── validation_agent
├── flight_search_agent (parallel)
├── summary_agent
└── booking_agent
```

This flat layout **fails** due to several ADK framework constraints:

### 3.1 LlmAgent turn boundary rule

A **turn** is the complete processing cycle between one user message and the
response the user sees. Within a turn, three things can happen:

| Action during a turn | Ends the turn? | What happens next |
|---|---|---|
| **Tool call** | ❌ No | Tool result returns to the **same agent** in the same turn. The agent keeps reasoning. |
| **Transfer to sub-agent** | ❌ No | Control moves to the target agent within the same turn. |
| **Text output** (by any LlmAgent) | ✅ **Yes** | The ADK runtime delivers the text to the user and **stops processing**. The next turn starts only when the user sends a new message. |

This is enforced by the ADK runtime, not by the LLM — no prompt or model
choice can change it.

#### Example: what works in one turn

```
User: "WAW to KRK tomorrow"
                                          ┌─── SINGLE TURN ──────────────────────┐
root_agent                                │                                       │
  ├─ transfer → validation_agent          │  (no text yet — turn continues)       │
  │    ├─ tool call: get_current_date()   │  → returns {today, tomorrow}          │
  │    ├─ tool call: validate_date(...)   │  → returns {valid: true}              │
  │    ├─ tool call: validate_route(...)  │  → returns {valid: true}              │
  │    └─ transfer → flight_search_and_summary_agent (SequentialAgent)            │
  │         ├─ step 1: ParallelAgent      │                                       │
  │         │    ├─ airline_a: tool call   │  → returns flights[]                  │
  │         │    └─ airline_b: tool call   │  → returns flights[]                  │
  │         └─ step 2: summary_agent      │                                       │
  │              └─ TEXT: "| Option # |…" │  ← TURN ENDS HERE                     │
                                          └───────────────────────────────────────┘
User sees: the flight results table
```

All tool calls and transfers happen **within the same turn**. The turn only
ends when `summary_agent` produces the table text.

#### Example: what breaks with a flat structure

```
User: "WAW to KRK tomorrow"
                                          ┌─── TURN 1 ───────────────────────────┐
root_agent                                │                                       │
  └─ transfer → validation_agent          │                                       │
       ├─ tool call: validate_route(...)  │  → returns {valid: true}              │
       └─ TEXT: "Route is valid,          │  ← TURN ENDS HERE                     │
               searching flights…"        │                                       │
                                          └───────────────────────────────────────┘
User sees: "Route is valid, searching flights…"
           (but NO flights are actually searched yet!)

         ⚠️ The user must now send ANOTHER message to trigger the next agent.

User: "ok" (or any message)
                                          ┌─── TURN 2 ───────────────────────────┐
root_agent                                │                                       │
  └─ transfer → flight_search_agent       │                                       │
       └─ TEXT: flights JSON              │  ← TURN ENDS HERE                     │
                                          └───────────────────────────────────────┘
User sees: raw flight data (but no summary table yet!)

         ⚠️ Yet another message needed…

User: "show me the table"
                                          ┌─── TURN 3 ───────────────────────────┐
root_agent                                │                                       │
  └─ transfer → summary_agent             │                                       │
       └─ TEXT: "| Option # | Flight # |…"│  ← TURN ENDS HERE                    │
                                          └───────────────────────────────────────┘
User sees: the table (after 3 messages instead of 1)
```

In the flat structure, each `LlmAgent` that produces text **kills the turn**.
What should be a single user request ("search WAW→KRK tomorrow") becomes a
three-message conversation. `SequentialAgent` and `ParallelAgent` solve this
because they are **workflow agents** — they do not produce text themselves,
they simply run their children in order (or in parallel) and the turn only
ends when the final child emits text.

### 3.2 LlmAgent cannot enforce execution order

`LlmAgent.sub_agents` is a list of **transfer targets**, not a pipeline.
The LLM picks which sub-agent to call based on descriptions and conversation
context. There is no guarantee that:

1. `flight_search_agent` runs **after** `validation_agent` completes.
2. `summary_agent` runs **after** `flight_search_agent` completes.

The LLM could skip validation, call summary before search results exist, or
re-run agents out of order.

### 3.3 SequentialAgent solves ordering but re-runs all children

`SequentialAgent` guarantees strict step ordering (search → summary), but it
**re-runs all children on every new user message**. If `booking_agent` were
inside the `SequentialAgent`, every "book #1" or "yes" follow-up would
re-trigger the entire parallel search + summary pipeline — wasteful and
incorrect.

### 3.4 The chosen architecture and why it works

The current nested structure solves all three problems:

```
root_agent (LlmAgent)
└── validation_agent (LlmAgent)
    ├── flight_search_and_summary_agent (SequentialAgent)
    │   ├── parallel_flight_search_agent (ParallelAgent)
    │   └── summary_agent (LlmAgent)
    └── booking_agent (LlmAgent)
```

| Problem | Solution |
|---|---|
| Turn boundary stops flow | `SequentialAgent` chains search → summary **within one turn** (no text output until summary) |
| No guaranteed execution order | `SequentialAgent` enforces step 1 (parallel search) completes before step 2 (summary) |
| Re-run on every message | `booking_agent` is a **peer** of the `SequentialAgent`, so follow-up messages route directly to it without re-running search |
| Validation before search | `validation_agent` (LlmAgent) uses tools to validate, then **transfers** to the pipeline only when valid |

This is the minimum nesting depth that satisfies all ADK constraints while
keeping each agent focused on a single responsibility.

### 3.5 Can better prompting or a stronger model fix the flat structure?

**No.** These are ADK **framework-level constraints**, not LLM reasoning
limitations. Model quality (e.g. `gemini-2.5-flash` vs `gemini-2.5-pro`)
is irrelevant for problems 3.1 and 3.3:

| Problem | Can prompting / better model fix it? | Why |
|---|---|---|
| Turn boundary rule (3.1) | ❌ No | The ADK runtime ends the turn when a sub-agent produces text. This is hardcoded in the SDK — no LLM can override it. |
| Execution order (3.2) | ⚠️ Partially | Stronger prompts and models improve reliability but ordering remains **probabilistic**. `SequentialAgent` makes it **deterministic**. |
| SequentialAgent re-run (3.3) | ❌ No | The framework always re-runs all children on each new message. No prompt can change this. |

The nested architecture uses the right ADK primitives (`SequentialAgent`,
`ParallelAgent`) to enforce what prompts alone cannot guarantee.

## 4. Where each part is implemented

- Root orchestrator: `my_multi_agent/agent.py`
- Validation and routing: `my_multi_agent/validation_agent/agent.py`
  - Exports: `validation_agent` (LlmAgent), tool functions, `_before_validation_agent` callback
- Parallel search: `my_multi_agent/parallel_flight_search_agent/agent.py`
  - Exports: `parallel_flight_search_agent` (ParallelAgent)
- Airline search agents:
  - `my_multi_agent/parallel_flight_search_agent/airline_a_flight_search_agent/agent.py` — exports `airline_a_flight_search_agent`, `search_airline_a_flights`
  - `my_multi_agent/parallel_flight_search_agent/airline_b_flight_search_agent/agent.py` — exports `airline_b_flight_search_agent`, `search_airline_b_flights`
- Summary: `my_multi_agent/summary_agent/agent.py`
  - Exports: `summary_agent` (LlmAgent, table rendering only)
- Booking: `my_multi_agent/booking_agent/agent.py`
  - Exports: `booking_agent` (LlmAgent, selection/confirmation/book_flight)
- Behavior constants and use cases: `my_multi_agent/requirements_spec.py`

## 5. Per-use-case sequence flow diagrams

Each diagram below corresponds to a `USE_CASE_*` in `requirements_spec.py`.

---

### USE_CASE_1_SUCCESS — successful end-to-end flow

```
User            root_agent       validation_agent     flight_search_and_     parallel_flight_     airline_a_flight_   airline_b_flight_   summary_agent       booking_agent
 │              (LlmAgent)       (LlmAgent)           summary_agent          search_agent         search_agent        search_agent        (LlmAgent)          (LlmAgent)
 │                  │                │                (SequentialAgent)       (ParallelAgent)       (LlmAgent)          (LlmAgent)               │                   │
 │                  │                │                     │                       │                     │                   │                   │                   │
 │◄── WELCOME ──────┤                │                     │                       │                     │                   │                   │                   │
 │                  │                │                     │                       │                     │                   │                   │                   │
 │ "waw-krk         │                │                     │                       │                     │                   │                   │                   │
 │  tomorrow"       │                │                     │                       │                     │                   │                   │                   │
 │─────────────────►│                │                     │                       │                     │                   │                   │                   │
 │                  │── transfer ───►│                     │                       │                     │                   │                   │                   │
 │                  │                │                     │                       │                     │                   │                   │                   │
 │                  │                │── get_current_date()│                       │                     │                   │                   │                   │
 │                  │                │◄─ {today, tomorrow} │                       │                     │                   │                   │                   │
 │                  │                │                     │                       │                     │                   │                   │                   │
 │                  │                │── validate_departure_date("2026-04-21")     │                     │                   │                   │                   │
 │                  │                │◄─ {valid: true}     │                       │                     │                   │                   │                   │
 │                  │                │                     │                       │                     │                   │                   │                   │
 │                  │                │── validate_route("WAW","KRK")               │                     │                   │                   │                   │
 │                  │                │◄─ {valid: true}     │                       │                     │                   │                   │                   │
 │                  │                │                     │                       │                     │                   │                   │                   │
 │                  │                │── transfer ────────►│                       │                     │                   │                   │                   │
 │                  │                │                     │                       │                     │                   │                   │                   │
 │                  │                │                     │──── step 1 ──────────►│                     │                   │                   │                   │
 │                  │                │                     │                       │──── (parallel) ────►│──────────────────►│                   │                   │
 │                  │                │                     │                       │                     │                   │                   │                   │
 │                  │                │                     │                       │                search_airline_     search_airline_          │                   │
 │                  │                │                     │                       │                a_flights()         b_flights()              │                   │
 │                  │                │                     │                       │                     │                   │                   │                   │
 │                  │                │                     │                       │◄── flights[] ───────┤── flights[] ─────►│                   │                   │
 │                  │                │                     │                       │     (both done)     │                   │                   │                   │
 │                  │                │                     │                       │                     │                   │                   │                   │
 │                  │                │                     │──── step 2 ────────────────────────────────────────────────────────────────────────►│                   │
 │                  │                │                     │                       │                     │                   │                   │                   │
 │◄──────── combined flight table ───────────────────────────────────────────────────────────────────────────────────────────────────────────────│                   │
 │  "| Option # | Flight # | Origin | Destination | Departure | Duration | Price | Airline |"            │                   │                   │                   │
 │  "Please select a flight by Option # or Flight #."      │                       │                     │                   │                   │                   │
 │                  │                │                     │                       │                     │                   │                   │                   │
 │ "book #1"        │                │                     │                       │                     │                   │                   │                   │
 │─────────────────►│                │                     │                       │                     │                   │                   │                   │
 │                  │── transfer ───►│                     │                       │                     │                   │                   │                   │
 │                  │                │── transfer (booking) ────────────────────────────────────────────────────────────────────────────────────────────────────────►│
 │                  │                │                     │                       │                     │                   │                   │                   │
 │◄──── "You selected Option #1, Flight #..., WAW→KRK, ..., $... USD" ───────────────────────────────────────────────────────────────────────────────────────────────│
 │      "Would you like to book Option #1?"                │                       │                     │                   │                   │                   │
 │                  │                │                     │                       │                     │                   │                   │                   │
 │ "yes"            │                │                     │                       │                     │                   │                   │                   │
 │──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────►│
 │                  │                │                     │                       │                     │  book_flight()    │                   │                   │
 │                  │                │                     │                       │                     │                   │                   │                   │
 │◄──── "It is only a demo agent and cannot really book this flight. I hope you enjoyed this demo :)" ───────────────────────────────────────────────────────────────│
 │                  │                │                     │                       │                     │                   │                   │                   │
```

**Routing:** root → validation_agent (3 tools) → flight_search_and_summary_agent (Sequential) → parallel_flight_search_agent (step 1) → summary_agent (step 2) → table.
**"book #1"**: root → validation_agent → booking_agent (bypasses SequentialAgent).
**"yes"**: directly → booking_agent (disallow_transfer_to_parent) → book_flight().

---

### USE_CASE_2_PAST_DATE — past date validation error

```
User            root_agent       validation_agent
 │              (LlmAgent)       (LlmAgent)
 │                  │                │
 │◄── WELCOME ──────┤                │
 │                  │                │
 │ "waw-krk         │                │
 │  last monday"    │                │
 │─────────────────►│                │
 │                  │── transfer ───►│
 │                  │                │
 │                  │                │── get_current_date()
 │                  │                │◄─ {today: "2026-04-20", ...}
 │                  │                │
 │                  │                │── validate_departure_date("2026-04-13")
 │                  │                │◄─ {valid: false, error: "Departure date is in the past"}
 │                  │                │
 │◄── "Departure date cannot be ─────┤   (flow stops — no search pipeline)
 │     in the past."                 │
 │                  │                │
```

**Routing:** root → validation_agent → validate_departure_date fails → error returned to user.
**Key:** Flight search pipeline is never entered.

---

### USE_CASE_3_UNSUPPORTED_ROUTE — unsupported route validation error

```
User            root_agent       validation_agent
 │              (LlmAgent)       (LlmAgent)
 │                  │                │
 │◄── WELCOME ──────┤                │
 │                  │                │
 │ "LBN-DSW         │                │
 │  next monday"    │                │
 │─────────────────►│                │
 │                  │── transfer ───►│
 │                  │                │
 │                  │                │── get_current_date()
 │                  │                │◄─ {today: "2026-04-20", ...}
 │                  │                │
 │                  │                │── validate_departure_date("2026-04-27")
 │                  │                │◄─ {valid: true}
 │                  │                │
 │                  │                │── validate_route("LBN","DSW")
 │                  │                │◄─ {valid: false, error: "Route LBN -> DSW is not supported.\nSupported routes:\n  WAW -> KRK\n  ..."}
 │                  │                │
 │◄── "Route LBN -> DSW is not ──────┤   (flow stops — no search pipeline)
 │     supported.                    │
 │     Supported routes:             │
 │       WAW -> KRK                  │
 │       WAW -> GDN                  │
 │       WAW -> WRO                  │
 │       KRK -> GDN                  │
 │       WAW -> KTW                  │
 │     Please choose one of the      │
 │     supported routes above        │
 │     and try again."               │
 │                  │                │
```

**Routing:** root → validation_agent → validate_route fails → error with supported routes list returned to user.
**Key:** Date validation passes, but route validation stops the flow before search.

---

### USE_CASE_4_SHOW_ROUTES — show supported routes then search

```
User            root_agent       validation_agent     flight_search_and_     parallel_flight_     airline_a_flight_   airline_b_flight_   summary_agent       booking_agent
 │              (LlmAgent)       (LlmAgent)           summary_agent          search_agent         search_agent        search_agent        (LlmAgent)          (LlmAgent)
 │                  │                │                (SequentialAgent)       (ParallelAgent)       (LlmAgent)          (LlmAgent)              │                   │
 │                  │                │                     │                       │                     │                   │                  │                   │
 │◄── WELCOME ──────┤                │                     │                       │                     │                   │                  │                   │
 │                  │                │                     │                       │                     │                   │                  │                   │
 │ "show routes"    │                │                     │                       │                     │                   │                  │                   │
 │─────────────────►│                │                     │                       │                     │                   │                  │                   │
 │                  │── transfer ───►│                     │                       │                     │                   │                  │                   │
 │                  │                │                     │                       │                     │                   │                  │                   │
 │                  │                │── before_agent_callback intercepts          │                     │                   │                  │                   │
 │                  │                │   (no LLM call)     │                       │                     │                   │                  │                   │
 │                  │                │                     │                       │                     │                   │                  │                   │
 │◄── "Supported routes:  ───────────┤                     │                       │                     │                   │                  │                   │
 │       WAW -> KRK                  │                     │                       │                     │                   │                  │                   │
 │       WAW -> GDN                  │                     │                       │                     │                   │                  │                   │
 │       WAW -> WRO                  │                     │                       │                     │                   │                  │                   │
 │       KRK -> GDN                  │                     │                       │                     │                   │                  │                   │
 │       WAW -> KTW                  │                     │                       │                     │                   │                  │                   │
 │     Tell me your route and        │                     │                       │                     │                   │                  │                   │
 │     date & time..."               │                     │                       │                     │                   │                  │                   │
 │                  │                │                     │                       │                     │                   │                  │                   │
 │                  │                │                     │                       │                     │                   │                  │                   │
 │    ... user then continues with USE_CASE_1_SUCCESS search flow from "waw-krk tomorrow" onward ...     │                   │                  │                   │
 │                  │                │                     │                       │                     │                   │                  │                   │
```

**Routing:** root → validation_agent → before_agent_callback intercepts "show routes" → deterministic response (no LLM call).
**Key:** After seeing routes, user continues with a normal search — same flow as USE_CASE_1_SUCCESS from step 2 onward.

## 6. Input-driven routing rules

| User input type | Responsible agent | What happens |
|---|---|---|
| New search request (`waw-krk tomorrow`) | `validation_agent` | Validate route/date, then run search pipeline |
| Route help (`show routes`, `show supported routes`, `show available routes`) | `validation_agent` | Return supported routes directly and stop |
| Selection/booking follow-up (`#1`, `book #1`, `SP526`, `yes`, `no`) | `booking_agent` | Stay in booking flow, no airline search |

## 7. Why this avoids wrong calls

- Selection messages never go to airline agents.
- Route-help messages never trigger parallel search.
- Validation errors stop before search starts.

## 8. Locking rules (how to keep flow inside the right agent)

### Current lock settings

| Agent | Setting | Purpose |
|---|---|---|
| `validation_agent` | `disallow_transfer_to_parent=True` | Prevent bouncing back to root mid-flow |
| `summary_agent` | `disallow_transfer_to_parent=True`, `disallow_transfer_to_peers=True` | Keep summary focused on table rendering only |
| `booking_agent` | `disallow_transfer_to_parent=True`, `disallow_transfer_to_peers=True` | Ensure follow-up messages remain in booking logic |
| `airline_a_flight_search_agent` | `disallow_transfer_to_parent=True`, `disallow_transfer_to_peers=True` | Airline A only returns search results |
| `airline_b_flight_search_agent` | `disallow_transfer_to_parent=True`, `disallow_transfer_to_peers=True` | Airline B only returns search results |

These settings are the primary guardrails that prevent unintended handoffs.

## 9. Sequential vs parallel: how to tell and how waiting works

### Sequential execution

`flight_search_and_summary_agent` is a `SequentialAgent` with this order:
1. `parallel_flight_search_agent` (`ParallelAgent`)
2. `summary_agent` (`LlmAgent`)

This guarantees summary runs **after** search stage.

### Parallel execution

`parallel_flight_search_agent` is a `ParallelAgent` with:
- `airline_a_flight_search_agent`
- `airline_b_flight_search_agent`

Both run concurrently.

### Waiting for both parallel branches

You do not need custom "join" code. ADK `ParallelAgent` waits for all branches
to finish, and because it is inside `SequentialAgent`, the next step
(`summary_agent`) starts only after both airline results are done.

## 10. Deterministic route-help response (no empty output)

In `validation_agent`, `before_agent_callback` (`_before_validation_agent`)
intercepts route-help requests and returns direct text content. This avoids
empty turns and avoids unnecessary tool/agent calls.

Output format is:

```text
Here are the supported routes:
- WAW -> KRK
- WAW -> GDN
- WAW -> WRO
- KRK -> GDN
- WAW -> KTW

Tell me your origin, destination, and preferred departure date & time.
```

## 11. Validation error formatting rules

Unsupported route errors are returned in multiline format:

```text
Route RZE -> GDA is not supported.
Supported routes:
- WAW -> KRK
- WAW -> GDN
- WAW -> WRO
- KRK -> GDN
- WAW -> KTW

Please choose one of the supported routes above and try again.
```

Validation instructions explicitly require returning tool error text as-is (no
line-break compression).

## 12. Summary/booking flow contract

For `book #1`:
1. `booking_agent` responds with selected flight details.
2. Then asks: `Would you like to book Option #1?`
3. It does **not** call booking tool in the same turn.

For `yes`:
1. `booking_agent` calls `book_flight`.
2. Returns demo disclaimer only:

```text
It is only a demo agent and cannot really book this flight.
I hope you enjoyed this demo :)
```

## 13. How to recognize flow in ADK UI

- Parallel stage: you will see both airline agent/tool activities during search.
- Sequential boundary: summary output appears only after both airline calls.
- Follow-up selection: only the booking_agent path should execute (no airline
  chatter).

## 14. Key ADK settings used in this project

- `sub_agents=[...]` on `LlmAgent`: enables transfer targets.
- `SequentialAgent(...)`: enforce strict order of stages.
- `ParallelAgent(...)`: run child agents concurrently.
- `before_agent_callback=...`: deterministic intercept for special intents.
- `disallow_transfer_to_parent=True`: prevent upward transfer.
- `disallow_transfer_to_peers=True`: prevent lateral transfer.
