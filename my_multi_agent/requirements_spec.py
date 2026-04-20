"""Behavior requirements for the my_multi_agent flight demo."""

SEARCH_PROMPT = (
    "Tell me your origin, destination, and preferred departure date & time."
)

WELCOME_PROMPT = (
    "Welcome to the ADK Multi-Agent Flight Search demo for domestic Poland routes!\n\n"
    f"{SEARCH_PROMPT}\n\n"
    'Type "show routes" to see all supported routes.'
)

DEMO_DISCLAIMER = (
    "It is only a demo agent and cannot really book this flight.\n"
    "I hope you enjoyed this demo :)"
)

SUPPORTED_ROUTES = [
    ("WAW", "KRK"),  # Warsaw Chopin -> Krakow Balice
    ("WAW", "GDN"),  # Warsaw Chopin -> Gdansk Lech Walesa
    ("WAW", "WRO"),  # Warsaw Chopin -> Wrocław Copernicus
    ("KRK", "GDN"),  # Krakow Balice -> Gdansk Lech Walesa
    ("WAW", "KTW"),  # Warsaw Chopin -> Katowice Pyrzowice
]

SUPPORTED_ROUTES_DISPLAY = "\n".join([f"  {o} -> {d}" for o, d in SUPPORTED_ROUTES])

USE_CASE_1_SUCCESS = {
    "name": "successful_e2e_flow",
    "steps": [
        {
            "actor": "agent",
            "message": WELCOME_PROMPT,
        },
        {
            "actor": "user",
            "message": "Search flights for waw-krk for tomorrow",
        },
        {
            "actor": "summary_agent",
            "message": (
                "Render one combined table with header: "
                "| Option # | Flight # | Origin | Destination | Departure Date and Time | Duration | Price | Airline |"
            ),
        },
        {
            "actor": "user",
            "message": "book #1",
        },
        {
            "actor": "booking_agent",
            "message": (
                "You have selected the flight: Option #1, Flight #..., from WAW to KRK, "
                "departing ..., with a duration of ... min, for $... USD, on ...\n"
                "Would you like to book Option #1?"
            ),
        },
        {
            "actor": "user",
            "message": "yes",
        },
        {
            "actor": "booking_agent",
            "message": DEMO_DISCLAIMER,
        },
    ],
}

USE_CASE_2_PAST_DATE = {
    "name": "past_date_validation_error",
    "steps": [
        {"actor": "agent", "message": WELCOME_PROMPT},
        {"actor": "user", "message": "Search flights for waw-krk for last monday"},
        {
            "actor": "validation_agent",
            "message": "Return an error that departure date cannot be in the past.",
        },
    ],
}

USE_CASE_3_UNSUPPORTED_ROUTE = {
    "name": "unsupported_route_validation_error",
    "steps": [
        {"actor": "agent", "message": WELCOME_PROMPT},
        {"actor": "user", "message": "Search flights for LBN-DSW to next monday"},
        {
            "actor": "validation_agent",
            "message": (
                "Return an error that route LBN-DSW is not supported and include "
                "the full supported routes list."
            ),
        },
    ],
}

USE_CASE_4_SHOW_ROUTES = {
    "name": "show_supported_routes_then_search",
    "steps": [
        {"actor": "agent", "message": WELCOME_PROMPT},
        {
            "actor": "user",
            "message": "Show routes / show supported routes / show available routes",
        },
        {
            "actor": "validation_agent",
            "message": (
                "Return all supported routes and then say: "
                '"Tell me your origin and destination route and date & time when you would like to fly"'
            ),
        },
        {
            "actor": "flow",
            "message": "Then continue with the same steps as USE_CASE_1_SUCCESS from search input onward.",
        },
    ],
}
