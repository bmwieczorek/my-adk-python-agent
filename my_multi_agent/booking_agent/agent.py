"""Booking subagent — handles flight selection, confirmation, and booking.

Peer of flight_search_and_summary_agent (SequentialAgent) under validation_agent.
Receives booking follow-ups ("book #1", "yes", "no") directly, bypassing the
SequentialAgent to avoid re-running the parallel flight search.
"""

from google.adk.agents import LlmAgent

from my_multi_agent.requirements_spec import DEMO_DISCLAIMER


def book_flight(
    row_number: int,
    flight_number: str,
    origin: str,
    destination: str,
    departure_datetime: str,
    duration_min: int,
    price_usd: float,
    airline: str,
) -> dict:
    """Simulate booking the selected flight and return a demo confirmation.

    Args:
        row_number: Selected option number from the summary table.
        flight_number: Flight number to book (e.g. SP142).
        origin: Origin airport IATA code.
        destination: Destination airport IATA code.
        departure_datetime: Departure date/time in UTC-like display format.
        duration_min: Flight duration in minutes.
        price_usd: Total price in USD.
        airline: Airline name (e.g. SkyPoland Airlines).

    Returns:
        Demo-only booking result.
    """
    return {
        "status": "demo_only",
        "row_number": row_number,
        "flight_number": flight_number,
        "origin": origin,
        "destination": destination,
        "departure_datetime": departure_datetime,
        "duration_min": duration_min,
        "airline": airline,
        "total_cost_usd": price_usd,
        "message": (
            DEMO_DISCLAIMER
        ),
    }


BOOKING_INSTRUCTION = f"""You are a flight booking agent.

Your only job is to handle flight selection and booking confirmation.
You read the previously presented flight table from conversation history.

When the user selects a flight (for example: "#1", "book #1", "SP526"):
1. Reply with exactly this 2-paragraph format:
   "You have selected the flight: Option #N, Flight #<flight_number>, from <origin> to <destination>, departing <departure_datetime>, with a duration of <duration_min> min, for $<price_usd> USD, on <airline>."

   "Would you like to book Option #N?"
2. IMPORTANT: Do NOT call book_flight in the same turn as initial selection.

When the user confirms ("yes", "book it", "confirm", etc.):
1. Call book_flight with the selected option's full flight details.
2. Respond with exactly:
   "{DEMO_DISCLAIMER}"

When the user declines ("no", "cancel", etc.):
- Thank them and let them know they can search again.

Important routing rules:
- You must handle all follow-up messages yourself (e.g. "#1",
  "go ahead with #1", "SP526", "book it", "yes", "no").
- Never transfer selection/booking messages to airline agents."""


booking_agent = LlmAgent(
    name="booking_agent",
    model="gemini-2.5-flash",
    instruction=BOOKING_INSTRUCTION,
    tools=[book_flight],
    disallow_transfer_to_parent=True,
    disallow_transfer_to_peers=True,
)
