"""Airline B (PolAir Express) subagent — fetches random flight prices."""

from google.adk.agents import LlmAgent

from my_multi_agent.parallel_flight_search_agent.common import (
    AirlineConfig,
    search_airline_flights,
)

_CONFIG = AirlineConfig(
    airline_name="PolAir Express",
    flight_prefix="PA",
    flight_num_range=(200, 899),
    hours_pool=[7, 9, 11, 14, 16, 19, 21],
    dep_minutes_pool=[0, 10, 25, 40, 50],
    duration_range=(55, 80),
    price_range=(38.0, 119.0),
)


def search_airline_b_flights(
    origin: str, destination: str, departure_date: str
) -> dict:
    """Search available flights from PolAir Express.

    Args:
        origin: Origin airport IATA code (e.g. WAW).
        destination: Destination airport IATA code (e.g. KRK).
        departure_date: Departure date in YYYY-MM-DD format.

    Returns:
        dict with list of available flights including prices in USD.
    """
    return search_airline_flights(origin, destination, departure_date, _CONFIG)


airline_b_flight_search_agent = LlmAgent(
    name="airline_b_flight_search_agent",
    model="gemini-2.5-flash",
    instruction="""You are a flight search agent for PolAir Express (Airline B).
Extract the origin, destination, and departure date from the conversation.
You MUST call search_airline_b_flights exactly once for each search request.
Return the tool result with all flights and prices in USD.
Do not produce chat prose outside of the tool result.""",
    tools=[search_airline_b_flights],
    disallow_transfer_to_parent=True,
    disallow_transfer_to_peers=True,
)
