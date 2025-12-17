"""
Applet: Arc Raiders Stats
Summary: Arc Raiders stats
Description: Shows current Arc Raiders player count and active event timers with map information.
Author: Chris Nourse
"""

load("ArcRaidersTitle.webp", ARC_RAIDERS_LOGO_ASSET = "file")
load("cache.star", "cache")
load("encoding/json.star", "json")
load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

ARC_RAIDERS_LOGO = ARC_RAIDERS_LOGO_ASSET.readall()

STEAM_API_URL = "https://api.steampowered.com/ISteamUserStats/GetNumberOfCurrentPlayers/v1/?appid=1808500"
METAFORGE_API_URL = "https://metaforge.app/api/arc-raiders/event-timers"

# Brand colors
COLOR_RED = "#F10E12"
COLOR_BLACK = "#17111A"
COLOR_GREEN = "#34F186"
COLOR_YELLOW = "#FACE0D"
COLOR_CYAN = "#81EEE6"
COLOR_WHITE = "#FFFFFF"

# Cache TTL values (in seconds)
PLAYER_CACHE_TTL = 600  # 10 minutes (http.get cache)
EVENTS_CACHE_TTL = 60  # 1 minute (manual cache with event expiration validation)

# Animation constants
ANIMATION_SCROLL_STEPS = 10  # Number of frames for scroll in/out animation
ANIMATION_PAUSE_FRAMES = 30  # Frames to pause (30 frames at 100ms = 3 seconds)
EVENT_CONTENT_HEIGHT = 18  # Height of event content (3 lines of text)
FRAMES_PER_SECOND = 10  # At 100ms per frame, update countdown every 10 frames (1 second)

# Scroll speed mapping (in milliseconds)
SCROLL_SPEED_MAP = {
    "slow": 150,
    "medium": 100,
    "fast": 50,
}

# Font names
FONT_TOM_THUMB = "tom-thumb"
FONT_CG_PIXEL_3X5 = "CG-pixel-3x5-mono"

# Screen constants
SCREEN_WIDTH = 64  # Display width in pixels
PLAYER_COUNT_HEIGHT = 6  # Height of player count display in pixels
CHAR_WIDTH = 4  # Character width in pixels for tom-thumb and CG-pixel-3x5-mono fonts

def main(config):
    show_player_count = config.bool("show_player_count", True)
    show_events = config.bool("show_events", True)
    scroll_speed = config.get("scroll_speed", "medium")

    # Get player count
    player_count = None
    if show_player_count:
        player_count = get_player_count()

    # Get event timers (with pre-calculated time remaining)
    # Note: Events are global and timezone-independent
    current_events = []
    events_error = False
    if show_events:
        events_result = get_current_events()
        if events_result == None:
            # API error occurred
            events_error = True
            current_events = []
        else:
            current_events = events_result

    return render_display(player_count, current_events, show_player_count, show_events, scroll_speed, events_error)

def get_player_count():
    """Fetch current player count from Steam API"""
    response = http.get(STEAM_API_URL, ttl_seconds = PLAYER_CACHE_TTL)
    if response.status_code != 200:
        return None

    data = response.json()
    if data != None and data.get("response") != None and data["response"].get("player_count") != None:
        player_count = int(data["response"]["player_count"])
        return player_count

    return None

def get_current_events():
    """Fetch event timers from MetaForge API and filter for currently active events

    Note: Arc Raiders events are global - they happen at the same UTC time for everyone.
    Time remaining is calculated in UTC and is the same for all players worldwide.
    """
    cached_data = cache.get("arc_raiders_events")
    if cached_data != None:
        events = json.decode(cached_data)

        # Validate cached data - check if any end_timestamp is in the past
        now_utc = time.now().in_location("UTC")
        valid = True
        for event in events:
            end_timestamp = event.get("end_timestamp", 0)
            if end_timestamp > 0 and end_timestamp < int(now_utc.unix):
                # Cached event has already ended, data is stale
                valid = False
                break
        if valid:
            return events

    response = http.get(METAFORGE_API_URL)
    if response.status_code != 200:
        return None  # Return None to indicate API error

    response_data = response.json()
    if not response_data:
        return None  # Return None to indicate API error

    # The API returns {"data": [...]} structure
    events = response_data.get("data", [])
    if not events:
        return []  # Return empty list - API worked but no events

    # Handle if events is not a list
    if type(events) != "list":
        return None  # Return None to indicate API error

    # Get current time in UTC
    now_utc = time.now().in_location("UTC")
    current_hour = now_utc.hour
    current_minute = now_utc.minute

    # Filter for events happening now
    active_events = []
    for event in events:
        # Skip if event is not a dict
        if type(event) != "dict":
            continue

        times = event.get("times")
        if times and type(times) == "list":
            for time_slot in times:
                if type(time_slot) != "dict":
                    continue

                start_time = parse_time(time_slot.get("start", ""))
                end_time = parse_time(time_slot.get("end", ""))

                if is_event_active(current_hour, current_minute, start_time, end_time):
                    # Create a proper UTC datetime for the end time
                    # Determine if end time is tomorrow in UTC (for midnight-spanning events)
                    start_minutes_utc = time_to_minutes(start_time["hour"], start_time["minute"])
                    end_minutes_utc = time_to_minutes(end_time["hour"], end_time["minute"])
                    current_minutes_utc = time_to_minutes(current_hour, current_minute)

                    # Check if event spans midnight
                    if end_minutes_utc < start_minutes_utc:
                        # Event spans midnight
                        if current_minutes_utc >= start_minutes_utc:
                            # We're in the pre-midnight portion, end is tomorrow
                            end_is_tomorrow_utc = True
                        else:
                            # We're in the post-midnight portion, end is today
                            end_is_tomorrow_utc = False
                    else:
                        # Normal event (doesn't span midnight)
                        # For active events, end should be later today
                        end_is_tomorrow_utc = False

                    # Build full UTC datetime for end time
                    end_day = now_utc.day + (1 if end_is_tomorrow_utc else 0)
                    end_datetime_utc = time.time(
                        year = now_utc.year,
                        month = now_utc.month,
                        day = end_day,
                        hour = end_time["hour"],
                        minute = end_time["minute"],
                        location = "UTC",
                    )

                    # Store event with end timestamp (for live countdown at render time)
                    active_events.append({
                        "name": event.get("name", "Unknown"),
                        "map": event.get("map", "Unknown"),
                        "start": time_slot.get("start", ""),
                        "end": time_slot.get("end", ""),
                        "end_timestamp": int(end_datetime_utc.unix),  # Store unix timestamp
                    })
                    break  # Only add each event once

    cache.set("arc_raiders_events", json.encode(active_events), ttl_seconds = EVENTS_CACHE_TTL)
    return active_events

def parse_time(time_str):
    """Parse time string like '14:00' into hour and minute with validation"""
    if not time_str or ":" not in time_str:
        return None

    parts = time_str.split(":")
    if len(parts) != 2:
        return None

    hour = int(parts[0])
    minute = int(parts[1]) if parts[1] else 0

    # Validate hour (0-23) and minute (0-59) ranges
    if hour < 0 or hour > 23 or minute < 0 or minute > 59:
        return None

    return {"hour": hour, "minute": minute}

def time_to_minutes(hour, minute):
    """Convert hour and minute to total minutes since midnight"""
    return hour * 60 + minute

def is_event_active(current_hour, current_minute, start_time, end_time):
    """Check if an event is currently active"""
    if not start_time or not end_time:
        return False

    current_minutes = time_to_minutes(current_hour, current_minute)
    start_minutes = time_to_minutes(start_time["hour"], start_time["minute"])
    end_minutes = time_to_minutes(end_time["hour"], end_time["minute"])

    # Handle events that span midnight
    if end_minutes < start_minutes:
        return current_minutes >= start_minutes or current_minutes < end_minutes

    return start_minutes <= current_minutes and current_minutes < end_minutes

def generate_event_animation(events, header_height):
    """Generate animation frames for events with scroll-pause-scroll effect and live countdown

    Args:
        events: List of event dictionaries
        header_height: Height of the header section in pixels

    Returns:
        render.Animation with frames for all events
    """
    frames = []
    full_height = 32  # Events use full screen height (32px)

    # Track total frame count for continuous countdown across all animations
    total_frame_count = 0

    for event in events:
        # Scroll in: create frames that slide the event into view from bottom
        for step in range(ANIMATION_SCROLL_STEPS + 1):
            # Start completely below screen (full_height + EVENT_CONTENT_HEIGHT), end at header_height
            start_offset = full_height + EVENT_CONTENT_HEIGHT
            offset = start_offset + (header_height - start_offset) * step // ANIMATION_SCROLL_STEPS

            # Calculate seconds elapsed based on total frames
            seconds_elapsed = total_frame_count // FRAMES_PER_SECOND

            # Use static text during scroll-in
            is_paused = False

            frames.append(
                render.Box(
                    width = SCREEN_WIDTH,
                    height = full_height,
                    child = render.Padding(
                        pad = (0, offset, 0, 0),
                        child = render_event(event, seconds_elapsed, is_paused),
                    ),
                ),
            )
            total_frame_count += 1

        # Pause: display event with live countdown and marquee for long text
        for _ in range(ANIMATION_PAUSE_FRAMES):
            # Calculate seconds elapsed based on total frames
            seconds_elapsed = total_frame_count // FRAMES_PER_SECOND

            # Marquee scrolling is active during pause
            is_paused = True

            frames.append(
                render.Box(
                    width = SCREEN_WIDTH,
                    height = full_height,
                    child = render.Padding(
                        pad = (0, header_height, 0, 0),
                        child = render_event(event, seconds_elapsed, is_paused),
                    ),
                ),
            )
            total_frame_count += 1

        # Scroll out: slide event out of view upward
        for step in range(1, ANIMATION_SCROLL_STEPS + 1):
            # Move from header_height up to negative (off screen top)
            offset = header_height - (header_height + EVENT_CONTENT_HEIGHT) * step // ANIMATION_SCROLL_STEPS

            # Calculate seconds elapsed based on total frames
            seconds_elapsed = total_frame_count // FRAMES_PER_SECOND

            # Continue marquee during scroll-out
            is_paused = True

            frames.append(
                render.Box(
                    width = SCREEN_WIDTH,
                    height = full_height,
                    child = render.Padding(
                        pad = (0, offset, 0, 0),
                        child = render_event(event, seconds_elapsed, is_paused),
                    ),
                ),
            )
            total_frame_count += 1

    return render.Animation(children = frames)

def format_time_remaining(remaining_seconds):
    """Format time remaining with improved readability for times over 60 minutes

    Args:
        remaining_seconds: Total seconds remaining

    Returns:
        Formatted string like "1h 20m" for >= 60min or "59m 30s" for < 60min
    """
    if remaining_seconds <= 0:
        return "ended"

    total_minutes = remaining_seconds // 60
    seconds = remaining_seconds % 60

    # For times >= 60 minutes, use hour and minute format
    if total_minutes >= 60:
        hours = total_minutes // 60
        minutes = total_minutes % 60
        return "ends in %dh %dm" % (hours, minutes)

    # For times < 60 minutes, use traditional minute and second format
    min_str = "0" + str(total_minutes) if total_minutes < 10 else str(total_minutes)
    sec_str = "0" + str(seconds) if seconds < 10 else str(seconds)
    return "ends in %sm %ss" % (min_str, sec_str)

def render_event(event, second_offset, is_paused = False):
    """Render a single event with marquee animation for long text during pause

    Args:
        event: Event dictionary with end_timestamp
        second_offset: Number of seconds to subtract from remaining time (for countdown animation)
        is_paused: Whether event is in pause/scroll-out phase (enables marquee)

    Calculates time remaining at render time for live countdown.
    Applies marquee animation to map/event names during pause and scroll-out.
    """

    # Calculate time remaining NOW (at render time) for live countdown
    now = time.now().in_location("UTC")
    end_timestamp = event.get("end_timestamp", 0)
    remaining_seconds = end_timestamp - int(now.unix) - second_offset

    # Format time optimized for 7-char limit "00x 00x" with maximum resolution
    if remaining_seconds > 0:
        total_minutes = remaining_seconds // 60
        seconds = remaining_seconds % 60
        total_hours = total_minutes // 60
        minutes = total_minutes % 60
        days = total_hours // 24
        hours = total_hours % 24

        # Choose format based on what fits in 7 chars with best resolution
        if total_hours >= 100:  # >= 100 hours, use days and hours
            d_str = ("0" + str(days)) if days < 10 else str(days)
            h_str = ("0" + str(hours)) if hours < 10 else str(hours)
            time_str = "ends in %sd %sh" % (d_str, h_str)
        elif total_minutes >= 100:  # >= 100 minutes, use hours and minutes
            h_str = ("0" + str(total_hours)) if total_hours < 10 else str(total_hours)
            m_str = ("0" + str(minutes)) if minutes < 10 else str(minutes)
            time_str = "ends in %sh %sm" % (h_str, m_str)
        else:  # < 100 minutes, use minutes and seconds
            m_str = ("0" + str(total_minutes)) if total_minutes < 10 else str(total_minutes)
            s_str = ("0" + str(seconds)) if seconds < 10 else str(seconds)
            time_str = "ends in %sm %ss" % (m_str, s_str)
    else:
        time_str = "ended"

    # Get event text
    map_name = event["map"]
    event_name = event["name"]

    # Calculate usable width (screen width minus left and right padding)
    usable_width = SCREEN_WIDTH - 4  # 2px padding on each side

    # Check if text is too long for screen (needs marquee)
    map_needs_marquee = len(map_name) * CHAR_WIDTH > usable_width
    event_needs_marquee = len(event_name) * CHAR_WIDTH > usable_width
    time_needs_marquee = len(time_str) * CHAR_WIDTH > usable_width

    # During pause and scroll-out: use marquee only for long text
    # During scroll-in: always use static text
    if is_paused and map_needs_marquee:
        map_text = render.Marquee(
            width = SCREEN_WIDTH,
            offset_start = 0,
            offset_end = 8,
            child = render.Text(
                content = map_name,
                font = FONT_TOM_THUMB,
                color = COLOR_WHITE,
            ),
            scroll_direction = "horizontal",
        )
    else:
        map_text = render.Text(
            content = map_name,
            font = FONT_TOM_THUMB,
            color = COLOR_WHITE,
        )

    if is_paused and event_needs_marquee:
        event_text = render.Marquee(
            width = SCREEN_WIDTH,
            offset_start = 0,
            offset_end = 8,
            child = render.Text(
                content = event_name,
                font = FONT_CG_PIXEL_3X5,
                color = COLOR_YELLOW,
            ),
            scroll_direction = "horizontal",
        )
    else:
        event_text = render.Text(
            content = event_name,
            font = FONT_CG_PIXEL_3X5,
            color = COLOR_YELLOW,
        )

    if is_paused and time_needs_marquee:
        time_text = render.Marquee(
            width = SCREEN_WIDTH,
            offset_start = 0,
            offset_end = 8,
            child = render.Text(
                content = time_str,
                font = FONT_CG_PIXEL_3X5,
                color = COLOR_RED,
            ),
            scroll_direction = "horizontal",
        )
    else:
        time_text = render.Text(
            content = time_str,
            font = FONT_CG_PIXEL_3X5,
            color = COLOR_RED,
        )

    # Left-align all event information with 2px left and 2px right padding
    return render.Box(
        width = SCREEN_WIDTH,
        height = EVENT_CONTENT_HEIGHT,
        child = render.Padding(
            pad = (2, 0, 2, 0),
            child = render.Column(
                cross_align = "start",
                children = [
                    map_text,
                    event_text,
                    time_text,
                ],
            ),
        ),
    )

def format_number(num):
    """Format number in K format (e.g., 286.2K)"""
    if num == None:
        return "N/A"

    if num >= 1000:
        thousands = num / 1000.0

        # Round to 1 decimal place by multiplying by 10, converting to int, then dividing by 10
        rounded = int(thousands * 10) / 10.0
        formatted = str(rounded)

        # Remove unnecessary .0 suffix
        if formatted.endswith(".0"):
            formatted = formatted[:-2]
        return "%sK" % formatted

    return str(num)

def render_display(player_count, current_events, show_player_count, show_events, scroll_speed, events_error = False):
    """Render the display based on what data is available"""

    # Calculate header height (logo + optional player count)
    header_height = 8  # Logo height
    if show_player_count:
        header_height += PLAYER_COUNT_HEIGHT

    # Create header overlay (title and player count)
    header_children = []
    header_children.append(render.Image(src = ARC_RAIDERS_LOGO))

    if show_player_count:
        player_text = format_number(player_count) if player_count != None else "N/A"
        header_children.append(
            render.Box(
                width = SCREEN_WIDTH,
                height = PLAYER_COUNT_HEIGHT,
                child = render.Padding(
                    pad = (1, 0, 0, 0),
                    child = render.Row(
                        main_align = "center",
                        cross_align = "center",
                        children = [
                            render.Text(
                                content = "Players:",
                                font = FONT_TOM_THUMB,
                                color = COLOR_CYAN,
                            ),
                            render.Text(
                                content = player_text,
                                font = FONT_TOM_THUMB,
                                color = COLOR_GREEN,
                            ),
                        ],
                    ),
                ),
            ),
        )

    # Create events background layer
    events_layer = None
    if show_events:
        if len(current_events) > 0:
            # Generate animation frames for events
            events_layer = generate_event_animation(current_events, header_height)
        else:
            # Show different message for API error vs no events
            if events_error:
                message = "API Error: Invalid data"
                message_color = COLOR_RED
            else:
                message = "No active events"
                message_color = COLOR_CYAN

            events_layer = render.Box(
                width = SCREEN_WIDTH,
                height = 32,
                child = render.WrappedText(
                    content = message,
                    font = FONT_TOM_THUMB,
                    color = message_color,
                ),
            )

    # Map scroll speed to delay value
    delay = SCROLL_SPEED_MAP.get(scroll_speed, 100)

    # Use Stack to overlay header on top of events
    if show_events and events_layer:
        return render.Root(
            delay = delay,
            child = render.Stack(
                children = [
                    events_layer,  # Background: scrolling events
                    render.Box(
                        width = SCREEN_WIDTH,
                        height = header_height,
                        color = COLOR_BLACK,
                        child = render.Column(children = header_children),  # Foreground: fixed header with opaque background
                    ),
                ],
            ),
        )
    else:
        # No events, just show header
        return render.Root(
            delay = delay,
            child = render.Column(children = header_children),
        )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Toggle(
                id = "show_player_count",
                name = "Show Player Count",
                desc = "Display current player count from Steam",
                icon = "users",
                default = True,
            ),
            schema.Toggle(
                id = "show_events",
                name = "Show Events",
                desc = "Display currently active event timers",
                icon = "calendar",
                default = True,
            ),
            schema.Dropdown(
                id = "scroll_speed",
                name = "Scroll Speed",
                desc = "Speed of event scrolling",
                icon = "gauge",
                default = "medium",
                options = [
                    schema.Option(
                        display = "Slow",
                        value = "slow",
                    ),
                    schema.Option(
                        display = "Medium",
                        value = "medium",
                    ),
                    schema.Option(
                        display = "Fast",
                        value = "fast",
                    ),
                ],
            ),
        ],
    )
