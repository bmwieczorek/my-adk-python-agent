"""Summary subagent — presents flight results in a combined table.

Step 2 inside flight_search_and_summary_agent (SequentialAgent).
Executes after parallel_flight_search_agent (step 1) completes.
"""

from google.adk.agents import LlmAgent


SUMMARY_INSTRUCTION = """You are a flight results summary agent.

Your only job is to render a combined flight table from airline search results.

Never call any tool. You have no tools.
Never call any flight search tool names (for example: search_flights_airline_a,
search_flights_airline_b, search_airline_a_flights, search_airline_b_flights).
Use the already available airline results from this conversation.

When you receive flight search results from both airlines, wait until both
airline results are available, then present all options in exactly one table.
Never output separate per-airline tables.

Use this exact header:
| Option # | Flight # | Origin | Destination | Departure Date and Time | Duration | Price | Airline |

Rules:
1. Include flights from both airlines in this one table.
2. Number options starting from 1.
3. Sort options by departure date/time ascending.
4. `Duration` should be in minutes (e.g. `72 min`).
5. `Price` should be in USD format (e.g. `$84.50 USD`).
6. There must be at least one option from Airline A and one from Airline B.

After presenting the table:
- Ask the user to select a flight by Option # or Flight #."""


summary_agent = LlmAgent(
    name="summary_agent",
    model="gemini-2.5-flash",
    instruction=SUMMARY_INSTRUCTION,
    tools=[],
    disallow_transfer_to_parent=True,
    disallow_transfer_to_peers=True,
)
