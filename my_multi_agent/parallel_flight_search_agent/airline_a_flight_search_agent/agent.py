"""Airline A (SkyPoland Airlines) subagent — fetches random flight prices."""

from google.adk.agents import LlmAgent

from my_multi_agent.parallel_flight_search_agent.common import (
    AirlineConfig,
    search_airline_flights,
)

_CONFIG = AirlineConfig(
    airline_name="SkyPoland Airlines",
    flight_prefix="SP",
    flight_num_range=(100, 999),
    hours_pool=[6, 8, 10, 13, 15, 18, 20],
    dep_minutes_pool=[0, 15, 30, 45],
    duration_range=(55, 85),
    price_range=(42.0, 134.0),
)


def search_airline_a_flights(
    origin: str, destination: str, departure_date: str
) -> dict:
    """Search available flights from SkyPoland Airlines.

    Args:
        origin: Origin airport IATA code (e.g. WAW).
        destination: Destination airport IATA code (e.g. KRK).
        departure_date: Departure date in YYYY-MM-DD format.

    Returns:
        dict with list of available flights including prices in USD.
    """
    return search_airline_flights(origin, destination, departure_date, _CONFIG)


airline_a_flight_search_agent = LlmAgent(
    name="airline_a_flight_search_agent",
    model="gemini-2.5-flash",
    instruction="""You are a flight search agent for SkyPoland Airlines (Airline A).
Extract the origin, destination, and departure date from the conversation.
You MUST call search_airline_a_flights exactly once for each search request.
Return the tool result with all flights and prices in USD.
Do not produce chat prose outside of the tool result.""",
    tools=[search_airline_a_flights],
    disallow_transfer_to_parent=True,
    disallow_transfer_to_peers=True,
)
