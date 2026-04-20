# my_multi_agent requirements

This document defines the required behavior contract for the ADK multi-agent
flight demo. The implementation is intentionally constrained to the use cases
below to avoid unnecessary tool calls and empty responses.

Source of truth in code: `my_multi_agent/requirements_spec.py`

## Scope

- Domestic Poland route demo only
- Flight search + selection + demo-only booking flow
- No real booking execution

## Required welcome prompt

The orchestrator must welcome with exactly:

`Welcome to the ADK Multi-Agent Flight Search demo for domestic Poland routes!`
`Tell me your origin, destination, and preferred departure date & time.`
`Type "show routes" to see all supported routes.`

## Supported routes

- WAW -> KRK
- WAW -> GDN
- WAW -> WRO
- KRK -> GDN
- WAW -> KTW

## Use case 1: successful end-to-end flow

1. Agent shows the welcome prompt.
2. User: `Search flights for waw-krk for tomorrow`
3. `summary_agent` returns one combined table with header:
   `| Option # | Flight # | Origin | Destination | Departure Date and Time | Duration | Price | Airline |`
4. User: `book #1`
5. `booking_agent` responds:
   `You have selected the flight: Option #1, Flight #..., from WAW to KRK, departing ..., with a duration of ... min, for $... USD, on ...`
   `Would you like to book Option #1?`
6. User: `yes`
7. `booking_agent` responds exactly:
   `It is only a demo agent and cannot really book this flight.`
   `I hope you enjoyed this demo :)`

## Use case 2: past date validation error

1. Agent shows the welcome prompt.
2. User: `Search flights for waw-krk for last monday`
3. `validation_agent` returns an error that the departure date cannot be in the
   past.

## Use case 3: unsupported route validation error

1. Agent shows the welcome prompt.
2. User: `Search flights for LBN-DSW to next monday`
3. `validation_agent` returns an error that route `LBN-DSW` is unsupported and
   includes the supported routes list.

## Use case 4: show supported routes then continue search

1. Agent shows the welcome prompt.
2. User: `Show routes` or `show supported routes` or `show available routes`
3. `validation_agent` returns all supported routes for the configuration and then says:
   `Tell me your origin, destination, and preferred departure date & time.`
4. Then continue with Use case 1 from Step 2 onward (`Search flights ...`) until
   successful demo completion.

## Interaction constraints

- For booking follow-ups (`#1`, `book #1`, flight number, `yes`, `no`), route to
  `booking_agent` only.
- Do not call airline search agents for booking follow-ups.
- Do not output separate airline tables.
- Do not emit empty responses.
- Airline agents are for search generation only; `summary_agent` owns table
  rendering and `booking_agent` owns selection and booking confirmation.
- Route-help requests (`show routes` variants) must be handled by `validation_agent`
  without triggering airline search calls.
