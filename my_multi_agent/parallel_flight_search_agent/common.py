"""Shared flight-search logic used by all airline sub-agents."""

import random
from dataclasses import dataclass, field


@dataclass(frozen=True)
class AirlineConfig:
    """Airline-specific parameters for flight generation."""

    airline_name: str
    flight_prefix: str
    flight_num_range: tuple[int, int]
    hours_pool: list[int] = field(default_factory=list)
    dep_minutes_pool: list[int] = field(default_factory=list)
    duration_range: tuple[int, int] = (55, 85)
    price_range: tuple[float, float] = (40.0, 130.0)


def search_airline_flights(
    origin: str,
    destination: str,
    departure_date: str,
    config: AirlineConfig,
) -> dict:
    """Generate random flights for a given airline configuration.

    Args:
        origin: Origin airport IATA code (e.g. WAW).
        destination: Destination airport IATA code (e.g. KRK).
        departure_date: Departure date in YYYY-MM-DD format.
        config: Airline-specific parameters.

    Returns:
        dict with list of available flights including prices in USD.
    """
    num_flights = random.randint(2, 3)
    hours = sorted(random.sample(config.hours_pool, num_flights))
    flights = []
    for h in hours:
        dep_min = random.choice(config.dep_minutes_pool)
        duration_min = random.randint(*config.duration_range)
        arr_total = h * 60 + dep_min + duration_min
        arr_h, arr_m = divmod(arr_total, 60)
        price = round(random.uniform(*config.price_range), 2)
        low, high = config.flight_num_range
        flights.append(
            {
                "flight_number": f"{config.flight_prefix}{random.randint(low, high)}",
                "airline": config.airline_name,
                "origin": origin.upper(),
                "destination": destination.upper(),
                "date": departure_date,
                "departure_time": f"{h:02d}:{dep_min:02d}",
                "arrival_time": f"{arr_h:02d}:{arr_m:02d}",
                "duration_min": duration_min,
                "price_usd": price,
                "cabin_class": "Economy",
            }
        )
    return {
        "status": "success",
        "airline": config.airline_name,
        "flights": flights,
    }
