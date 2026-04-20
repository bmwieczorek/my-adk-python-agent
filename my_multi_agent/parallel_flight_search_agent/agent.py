"""Parallel flight search agent — runs both airline searches concurrently.

ParallelAgent that dispatches to airline_a_flight_search_agent and
airline_b_flight_search_agent, waiting for both to complete before
the SequentialAgent advances to summary_agent (step 2).
"""

from google.adk.agents import ParallelAgent

from my_multi_agent.parallel_flight_search_agent.airline_a_flight_search_agent.agent import (
    airline_a_flight_search_agent,
)
from my_multi_agent.parallel_flight_search_agent.airline_b_flight_search_agent.agent import (
    airline_b_flight_search_agent,
)

parallel_flight_search_agent = ParallelAgent(
    name="parallel_flight_search_agent",
    sub_agents=[airline_a_flight_search_agent, airline_b_flight_search_agent],
    description="Fetches flight prices from both airlines in parallel.",
)
