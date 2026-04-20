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

## 3. Where each part is implemented

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

## 4. Per-use-case sequence flow diagrams

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

## 5. Input-driven routing rules

| User input type | Responsible agent | What happens |
|---|---|---|
| New search request (`waw-krk tomorrow`) | `validation_agent` | Validate route/date, then run search pipeline |
| Route help (`show routes`, `show supported routes`, `show available routes`) | `validation_agent` | Return supported routes directly and stop |
| Selection/booking follow-up (`#1`, `book #1`, `SP526`, `yes`, `no`) | `booking_agent` | Stay in booking flow, no airline search |

## 6. Why this avoids wrong calls

- Selection messages never go to airline agents.
- Route-help messages never trigger parallel search.
- Validation errors stop before search starts.

## 7. Locking rules (how to keep flow inside the right agent)

### Current lock settings

| Agent | Setting | Purpose |
|---|---|---|
| `validation_agent` | `disallow_transfer_to_parent=True` | Prevent bouncing back to root mid-flow |
| `summary_agent` | `disallow_transfer_to_parent=True`, `disallow_transfer_to_peers=True` | Keep selection + booking inside summary flow |
| `booking_agent` | `disallow_transfer_to_parent=True`, `disallow_transfer_to_peers=True` | Ensure follow-up messages remain in booking logic |
| `airline_a_flight_search_agent` | `disallow_transfer_to_parent=True`, `disallow_transfer_to_peers=True` | Airline A only returns search results |
| `airline_b_flight_search_agent` | `disallow_transfer_to_parent=True`, `disallow_transfer_to_peers=True` | Airline B only returns search results |

These settings are the primary guardrails that prevent unintended handoffs.

## 8. Sequential vs parallel: how to tell and how waiting works

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

## 9. Deterministic route-help response (no empty output)

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

## 10. Validation error formatting rules

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

## 11. Summary/booking flow contract

For `book #1`:
1. Summary agent responds with selected flight details.
2. Then asks: `Would you like to book Option #1?`
3. It does **not** call booking tool in the same turn.

For `yes`:
1. Summary calls `book_flight`.
2. Returns demo disclaimer only:

```text
It is only a demo agent and cannot really book this flight.
I hope you enjoyed this demo :)
```

## 12. How to recognize flow in ADK UI

- Parallel stage: you will see both airline agent/tool activities during search.
- Sequential boundary: summary output appears only after both airline calls.
- Follow-up selection: only the booking_agent path should execute (no airline
  chatter).

## 13. Key ADK settings used in this project

- `sub_agents=[...]` on `LlmAgent`: enables transfer targets.
- `SequentialAgent(...)`: enforce strict order of stages.
- `ParallelAgent(...)`: run child agents concurrently.
- `before_agent_callback=...`: deterministic intercept for special intents.
- `disallow_transfer_to_parent=True`: prevent upward transfer.
- `disallow_transfer_to_peers=True`: prevent lateral transfer.
