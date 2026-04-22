"""Validation subagent — checks departure date and route validity."""

from datetime import datetime, timedelta, timezone

from google.adk.agents import LlmAgent, SequentialAgent
from google.genai import types

from my_multi_agent.parallel_flight_search_agent.agent import parallel_flight_search_agent
from my_multi_agent.requirements_spec import (
    SEARCH_PROMPT,
    SUPPORTED_ROUTES,
    WELCOME_PROMPT,
)
from my_multi_agent.booking_agent.agent import booking_agent
from my_multi_agent.summary_agent.agent import summary_agent


def _extract_user_text(content: types.Content | None) -> str:
    """Extract plain text from user content payload."""
    if not content or not content.parts:
        return ""
    chunks: list[str] = []
    for part in content.parts:
        if getattr(part, "text", None):
            chunks.append(part.text)
    return " ".join(chunks).strip()


def _is_show_routes_request(user_text: str) -> bool:
    """Check whether the user is asking to see supported routes."""
    text = user_text.lower()
    return (
        "show routes" in text
        or "supported routes" in text
        or "available routes" in text
    )


def _format_supported_routes_lines() -> str:
    """Format supported routes as one route per line."""
    return "\n".join([f"- {o} -> {d}" for o, d in SUPPORTED_ROUTES])


def _before_validation_agent(callback_context):
    """Deterministically handle route-help requests with a direct response."""
    user_text = _extract_user_text(callback_context.user_content)
    if _is_show_routes_request(user_text):
        return types.Content(
            role="model",
            parts=[
                types.Part(
                    text=(
                        "Here are the supported routes:\n"
                        f"{_format_supported_routes_lines()}\n\n"
                        f"{SEARCH_PROMPT}"
                    )
                )
            ],
        )
    return None


def get_current_date() -> dict:
    """Return today's date in UTC so the LLM can resolve relative dates.

    Returns:
        dict with 'today' in YYYY-MM-DD format.
    """
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    tomorrow = (datetime.now(timezone.utc) + timedelta(days=1)).strftime("%Y-%m-%d")
    return {"today": today, "tomorrow": tomorrow}


def validate_departure_date(departure_date: str) -> dict:
    """Check that the departure date is not in the past.

    Args:
        departure_date: Departure date in YYYY-MM-DD format.

    Returns:
        dict with 'valid' bool and optional 'error' string.
    """
    today = datetime.now(timezone.utc).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    try:
        date = datetime.strptime(departure_date, "%Y-%m-%d").replace(
            tzinfo=timezone.utc
        )
    except ValueError:
        return {
            "valid": False,
            "error": (
                f"Invalid departure date format: {departure_date}. "
                "Please provide the date in YYYY-MM-DD format."
            ),
        }
    if date < today:
        return {
            "valid": False,
            "error": (
                f"Departure date {departure_date} is in the past. "
                "Please provide a future date."
            ),
        }
    return {"valid": True, "departure_date": departure_date}


def validate_route(origin: str, destination: str) -> dict:
    """Check that origin→destination is a supported domestic Poland route.

    Args:
        origin: Origin airport IATA code (e.g. WAW).
        destination: Destination airport IATA code (e.g. KRK).

    Returns:
        dict with 'valid' bool and optional 'error' string listing supported routes.
    """
    o, d = origin.strip().upper(), destination.strip().upper()
    if (o, d) in SUPPORTED_ROUTES:
        return {"valid": True, "origin": o, "destination": d}
    return {
        "valid": False,
        "error": (
            f"Route {o} -> {d} is not supported.\n"
            "Supported routes:\n"
            f"{_format_supported_routes_lines()}\n\n"
            "Please choose one of the supported routes above and try again."
        ),
    }


def show_supported_routes() -> str:
    """Return all supported routes and ask user for search details."""
    return (
        "Here are the supported routes:\n"
        f"{_format_supported_routes_lines()}\n\n"
        f"{SEARCH_PROMPT}"
    )


validation_agent = LlmAgent(
    name="validation_agent",
    model="gemini-2.5-flash",
    instruction=f"""You are a flight search validation and orchestration agent.

IMPORTANT: You can ONLY call the provided tools. Do NOT write code.

First, classify the user message intent:
- If user asks to show supported/available routes (e.g. "show routes",
  "show supported routes", "show available routes"), call show_supported_routes
  and respond with the returned text exactly, then STOP.
- If it is a selection/booking follow-up (e.g. "#1", "book #1", "SP526",
  "go ahead with #1", "yes", "no"), DO NOT validate and DO NOT run airline
  search. Immediately transfer to booking_agent.
- If it is not a clear flight-search request and not a booking follow-up,
  respond with exactly this prompt and stop:
  "{WELCOME_PROMPT}"
- Otherwise treat it as a flight-search request and continue validation.

To resolve relative dates like "tomorrow", "next Friday", etc.:
1. First call get_current_date to learn today's date.
2. Compute the target date mentally (e.g. tomorrow = today + 1 day).
3. Call validate_departure_date with the resolved YYYY-MM-DD string.
4. Call validate_route with the origin and destination airport codes.

Always call all required tools. Report ALL validation errors found.
If validation fails:
- Return the exact `error` text from the failed validation tool response.
- Do NOT rephrase, compress, or remove line breaks.
- STOP (do not transfer to flight search agents).

If validation passes:
1. Do NOT stop at a plain "request is valid" response.
2. Immediately transfer to flight_search_and_summary_agent.
3. Ensure both airline_a_flight_search_agent and airline_b_flight_search_agent complete and each returns at least
   one flight option.
4. flight_search_and_summary_agent runs in strict order:
   - parallel_flight_search_agent (parallel): airline_a_flight_search_agent + airline_b_flight_search_agent
   - summary_agent: one combined table after both airline results are available.
5. Your task is complete only after summary_agent has presented that single table.""",
    before_agent_callback=_before_validation_agent,
    tools=[
        get_current_date,
        validate_departure_date,
        validate_route,
        show_supported_routes,
    ],
    disallow_transfer_to_parent=True,
    sub_agents=[
        SequentialAgent(
            name="flight_search_and_summary_agent",
            description=(
                "Runs parallel airline searches first, then combines and summarizes."
            ),
            sub_agents=[
                parallel_flight_search_agent,
                summary_agent,
            ],
        ),
        booking_agent,
    ],
)
