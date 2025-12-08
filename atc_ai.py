"""
Base implementation for AI ATC that:
- Uses httpx (sync, with timeout) to query a stateless DCS REST server.
- Wraps DCS data in Pydantic models.
- Exposes OpenAI function-calling tools:
    - get_radar_picture(...) : GET radar tracks and optionally filter them
    - send_engagement_order(...) : POST a command back to DCS

This is the minimal, synchronous "LLM → tool → DCS" flow.
"""

from __future__ import annotations

import json
from math import sqrt
from typing import List, Optional

import httpx
from pydantic import BaseModel
from openai import OpenAI

# ---------------------------------------------------------------------------
# DCS DATA MODELS
# ---------------------------------------------------------------------------

class Detection(BaseModel):
    radar: bool
    optic: bool
    visual: bool

class Position(BaseModel):
    x: float
    y: float
    z: float

class Track(BaseModel):
    lastSeenTimeSec: float
    altitudeM: float
    RCS: float
    callsign: str
    trackId: str
    rangeKm: float
    groupName: str
    detection: Detection
    coalition: str          # "RED" / "BLUE" / whatever you use
    unitCategory: str       # "AIRPLANE" / "HELICOPTER" / ...
    bearingDeg: float
    position: Position
    unitName: str
    headingDeg: float
    typeName: str           # "MiG-21Bis", "Su-27", ...
    groundSpeedKmh: float

class CommandResult(BaseModel):
    success: bool
    message: Optional[str] = None
    # Extend with any other fields you decide to return from DCS.

# ---------------------------------------------------------------------------
# DCS CLIENT (SYNC, TIMEOUT-AWARE)
# ---------------------------------------------------------------------------

class DcsClient:
    """
    Thin synchronous client around the DCS REST API.

    - Uses httpx with blocking calls.
    - timeout_sec: upper bound on how long we wait for DCS.
    """

    def __init__(self, base_url: str, timeout_sec: float = 1.0):
        self.base_url = base_url.rstrip("/")
        self.timeout_sec = timeout_sec

    def _url(self, path: str) -> str:
        return f"{self.base_url}/{path.lstrip('/')}"

    # --- GET: Radar tracks ---------------------------------------------------

    def atc_traffic(self) -> List[Track]:
        try:
            url = self._url("atc/traffic?atcUnit=Ground-1-1")
            print(f"GET {url}")
            resp = httpx.get(url, timeout=self.timeout_sec)
            resp.raise_for_status()
        except httpx.TimeoutException as e:
            raise RuntimeError(
                f"DCS /atc/traffic request timed out after {self.timeout_sec}s"
            ) from e
        except httpx.HTTPError as e:
            raise RuntimeError(f"DCS /atc/traffic HTTP error: {e}") from e

        data = resp.json()
        print(f"atc_traffic resp: {data}")
        return [Track.model_validate(item) for item in data]

    # --- POST: Commands ------------------------------------------------------

    def post_command(self, path: str, payload: dict) -> CommandResult:
        try:
            resp = httpx.post(
                self._url(path),
                json=payload,
                timeout=self.timeout_sec,
            )
            resp.raise_for_status()
        except httpx.TimeoutException as e:
            raise RuntimeError(
                f"DCS POST request timed out after {self.timeout_sec}s"
            ) from e
        except httpx.HTTPError as e:
            raise RuntimeError(f"DCS POST HTTP error: {e}") from e

        data = resp.json()
        return CommandResult.model_validate(data)

# ---------------------------------------------------------------------------
# SIMPLE BUSINESS LOGIC: FILTERING / UTILITIES
# ---------------------------------------------------------------------------

def filter_tracks(
    tracks: List[Track],
    coalition: Optional[str] = None,
    max_range_km: Optional[float] = None,
) -> List[Track]:
    """
    Light business logic:
    - Optionally filter by coalition (exact match).
    - Optionally filter by maximum range in km.
    """
    res = tracks

    if coalition is not None:
        col = coalition.upper()
        res = [t for t in res if t.coalition.upper() == col]

    if max_range_km is not None:
        res = [t for t in res if t.rangeKm <= max_range_km]

    return res


def distance_km(a: Track, b: Track) -> float:
    """
    Example utility: compute 3D distance in km between two tracks
    using their Position.x/y/z, assuming meters in DCS coordinates.
    """
    dx = a.position.x - b.position.x
    dy = a.position.y - b.position.y
    dz = a.position.z - b.position.z
    return sqrt(dx * dx + dy * dy + dz * dz) / 1000.0


# ---------------------------------------------------------------------------
# OPENAI CLIENT & TOOL DEFINITIONS
# ---------------------------------------------------------------------------

# Instantiate OpenAI client (expects OPENAI_API_KEY in env)
client = OpenAI()

# Global DCS client instance – you can parameterize this if needed
dcs = DcsClient(base_url="http://localhost:5017", timeout_sec=2.0)


# --- Tool: get_radar_picture -----------------------------------------------

def tool_atc_traffic(
    coalition: Optional[str] = None,
    max_range_km: Optional[float] = None,
) -> list[dict]:
    """
    Backing implementation for the atc_traffic tool.
    - Fetch radar tracks from DCS.
    - Apply light filtering.
    - Return plain JSON-serializable dicts.
    """
    tracks = dcs.atc_traffic()
    print(f"tool_atc_traffic tracks: {tracks}")
#    tracks = filter_tracks(tracks, coalition=coalition, max_range_km=max_range_km)
    serializable = [track.model_dump() for track in tracks]
#    print(f"\ntool_atc_traffic serializable: {serializable}")
#    print(f"\ntool_atc_traffic json.dumps(serializable): {json.dumps(serializable)}")
    return json.dumps(serializable)

# --- OpenAI tool schema -----------------------------------------------------

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "atc_traffic",
            "description": (
                "Fetch the current radar picture from ATC radar. Returns a JSON "
                "array of Track objects. Each Track has: lastSeenTimeSec (monotonic time), "
                "altitude (in meeters), RCS (Radar Cross Section), callsign, trackId, "
                "rangeKm (km from radar point), groupName, detection {radar|optic|visual "
                "booleans}, coalition (e.g. RED/BLUE), unitCategory (e.g. "
                "AIRPLANE/HELICOPTER), bearingDeg (from radar point), position {x,y,z in "
                "meters), unitName, headingDeg (absolute unit movement heading), typeName (DCS unit type), "
                "groundSpeedKmh (ground speed in km/h)"
            ),
        },
    }
]

# ---------------------------------------------------------------------------
# SINGLE-TURN AI ATC CALL WITH TOOL SUPPORT
# ---------------------------------------------------------------------------

llm_prompt = """You are: military air traffic control on Sanaki air base tower.
Your task: Establish initial arrival contact and asses basic data and intention

Suplementary information to help understand the callouts:
Radio communication sides:
Flight - set of military aircrafts
Pilot - single pilot in flight. those can be 1 - leads, 2 - wingman, 3 - second flight element lead, 4 - second flight element wingman
Airbase ATC (Air Traffic Control), AWACS (Airborne Early Warning and Control), GCI (Ground Control Interception)

ATC callsigns: Sanaki, Kutaisi, Sochi, Gudauta, Sukumi, Vaziani, Tbilisi, Kobuleti, Batumi
Flight callsigns: Enfield, Springfield, Uzi, Colt, Dodge, Ford, Chevy, Pontiac, Viper
Flight callsign format: <Callsign>-X-Y where X is flight number and Y represent pilot rank in given flight. Y can be omitted when flight lead 1 represent whole flight.

Correct callout format:
<Recipient>, <Sender>, <Callout intent and remain part of the message>

Current Sanaki ATIS:
Sanaki airbase information Bravo, time 1400 Zulu. IFR in effect, Wind 240 at 15 knots, visibility 2 miles, broken at 1000 feet, temperature 20, dew point 12, altimeter 29.92. Active runway 25.

Your task and execution:
- Print RAW radio callout (use <unclear/unintelligible> for garbled parts)
- Make short analisys of callout in scope of it's format validity and proper brevity
- Asses who is talking to who
- Asses what it means 
- Asses what is the expectation or intent of calling side
- Asses elementary information/data provided in callout
- Plan for sequence of funtion calls to fulfill the callout expectation
- Perform function calls according to the plan (do not put call as text but actually use tool to call given function)
- Respond in brevity format to calling side

Important: Always provide analisys first, before calling any functions analize the tasks and execution plan!
"""

def run_ai_atc_turn(user_message: str) -> str:
    """
    One-turn interaction:

    1. Ask the model with tools enabled.
    2. If it calls a tool, execute the tool (which calls DCS via httpx).
    3. Send the tool result back to the model.
    4. Return the final natural-language ATC reply.

    This is synchronous and only calls DCS inside tool functions.
    """

    print("AI ATC: Calling GPT")
    # 1) First call: let the model decide whether to use tools
    first = client.chat.completions.create(
        model="gpt-4.1-mini",  # adjust as needed
        messages=[
            {
                "role": "system",
                "content": llm_prompt
            },
            {"role": "user", "content": user_message},
        ],
        tools=TOOLS,
        tool_choice="auto",
    )

    msg = first.choices[0].message

    print(f"AI ATC:Respons: {msg}")
    print("AI ATC: Calling Tool")
    # 2) If no tool call, return the model's response directly
    if not msg.tool_calls:
        return msg.content or ""

    # 3) Execute each requested tool call
    tool_messages = []

    for tool_call in msg.tool_calls:
        fn_name = tool_call.function.name
        args = json.loads(tool_call.function.arguments or "{}")

        if fn_name == "atc_traffic":
            result = tool_atc_traffic(
#                coalition=args.get("coalition"),
#                max_range_km=args.get("max_range_km"),
            )
        else:
            # Defensive programming in case the model references unknown tool
            result = {"error": f"Unknown tool {fn_name}"}

        tool_messages.append(
            {
                "role": "tool",
                "tool_call_id": tool_call.id,
                "name": fn_name,
                "content": result,
            }
        )

    print("AI ATC: Calling GPT")
    # 4) Second call: give the model the tool outputs and get final answer
    second = client.chat.completions.create(
        model="gpt-4.1-mini",
        messages=[
            {
                "role": "system",
                "content": llm_prompt
            },
            {"role": "user", "content": user_message},
            msg,
            *tool_messages,
        ],
    )

    return second.choices[0].message.content or ""


# ---------------------------------------------------------------------------
# EXAMPLE USAGE (for manual testing)
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    # Example conversation input
    question = ("Sanaki, Springfield11, request picture")
    reply = run_ai_atc_turn(question)
    print("AI ATC:", reply)
