"""Multi-agent flight search orchestrator.

Demonstrates ADK sequential and parallel agent composition:
  1. root_agent                    — greets and delegates
  2. validation_agent              — validates route and date
  3. flight_search_and_summary_agent (SequentialAgent):
     a. parallel_flight_search_agent (ParallelAgent):
        - airline_a_flight_search_agent — queries SkyPoland Airlines
        - airline_b_flight_search_agent — queries PolAir Express
     b. summary_agent              — presents combined results table
  4. booking_agent                 — handles selection and booking confirmation

Directory structure:
  my_multi_agent/
  ├── agent.py                              ← root_agent
  ├── validation_agent/agent.py             ← validation + orchestration
  ├── parallel_flight_search_agent/
  │   ├── agent.py                          ← ParallelAgent
  │   ├── airline_a_flight_search_agent/agent.py
  │   └── airline_b_flight_search_agent/agent.py
  ├── summary_agent/agent.py                ← table rendering
  ├── booking_agent/agent.py                ← selection + booking
  └── requirements_spec.py                  ← behavior contracts

Run locally:
    adk web
    # Then select "flight_search_orchestrator" in the UI

    # Or via A2A:
    A2A_AGENT_MODULE=my_multi_agent.agent python a2a_server.py
"""

from google.adk.agents import LlmAgent

from my_multi_agent.requirements_spec import WELCOME_PROMPT
from my_multi_agent.validation_agent.agent import validation_agent

root_agent = LlmAgent(
    name="flight_search_orchestrator",
    model="gemini-2.5-flash",
    instruction=f"""You are a flight search orchestrator for domestic flights in Poland.

When the conversation starts and the user has not yet provided flight details,
greet them with exactly:
"{WELCOME_PROMPT}"

Flow:
1. Route user intent first:
   - Transfer all user messages to validation_agent.
   - validation_agent will route search requests vs booking follow-ups.
2. validation_agent handles validation and, if valid, continues the rest of the
   pipeline (parallel airline pricing + summary table via summary_agent).
3. booking_agent handles selection and booking confirmation flow.

Do not stop at validation. Ensure the full flow runs until priced flight options
are presented when the request is valid.""",
    sub_agents=[validation_agent],
    description=(
        "Multi-agent flight search for domestic Poland flights. "
        "Demonstrates sequential + parallel agent orchestration."
    ),
)
