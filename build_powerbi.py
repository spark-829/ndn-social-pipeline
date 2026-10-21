"""Build the NDN Power BI report as a PBIP project (plain-text files) from the CSVs of export_powerbi.py.

Nothing is clicked in Power BI Desktop: the data model is written as TMDL and every visual as one PBIR
visual.json, the same idea as build_tableau_workbook.py. Desktop only opens the result.

    powerbi/NDN_dashboard.pbip                 open this in Power BI Desktop
    powerbi/NDN_dashboard.SemanticModel/       tables (CSV loads), relationships, DAX measures (TMDL)
    powerbi/NDN_dashboard.Report/              7 pages, "Cozy Cove" theme (PBIR JSON)

Every page has its own filter row and a Reset button ("Clear all slicers" acts on that page only); slicers are not
synced, so a filter never reaches another page.

Rebuilding replaces the pages and the model, so edits made by hand in Desktop are lost: make lasting changes here.
Close Power BI Desktop before rebuilding (Desktop writes its in-memory copy back on save).

Usage:  py export_powerbi.py   then   py build_powerbi.py
"""
import json
import shutil
import uuid
from pathlib import Path

BASE = Path(__file__).resolve().parent
PBI = BASE / "powerbi"
DATA = PBI / "data"
THEMES = PBI / "theme"
NAME = "NDN_dashboard"
REPORT = PBI / f"{NAME}.Report"
MODEL = PBI / f"{NAME}.SemanticModel"
NS = uuid.UUID("6f1c2a7e-3b0d-4c5e-9a7f-1d2e3f405061")   # fixed, so lineage tags stay the same between builds

# "Cozy Cove" theme, sampled from Live at The Cozy Cove thumbnails (2026-10-21): warm near-black #161613, wood
# #61462a, amber title gold #e9a311, cream text. Platform colours (TABLEAU_DATA.md v3 plan) pass validate_palette.js
# --mode dark --pairs all on CARD; TikTok vs Instagram is a CVD warning, so every platform mark also carries its name.
PAGE, CARD, LINE, GRID = "#12100c", "#1e1a14", "#3a3124", "#2b261d"
INK, INK2, INK3 = "#f3e9d2", "#c9b99a", "#9a8b70"
GOLD = "#e9a311"
HI, LO = GOLD, "#7a6a52"                      # gold = the thing to look at, warm gray = context
BAR_DIM = "#5c4a2a"                           # data bars inside tables
TITLE_FONT = "Georgia"                        # serif, like the session title cards
PLATFORMS = {"TikTok": "#00a0d0", "YouTube": "#e8302a", "Instagram": "#d6249f"}
SHIFT = 66                                    # room for the filter row under each page header
DISCLAIMER = ("Independent analysis of public data, not affiliated with Nine Degrees North. "
              "Only real daily snapshots are shown; the labelled synthetic backfill is left out.")

SCHEMA = "https://developer.microsoft.com/json-schemas/fabric"
VC_SCHEMA = f"{SCHEMA}/item/report/definition/visualContainer/2.13.0/schema.json"
THEME_VERSIONS = {"visual": "2.12.0", "report": "3.4.0", "page": "2.3.1"}


def tag(*parts) -> str:
    return str(uuid.uuid5(NS, ".".join(parts)))


def write_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False), encoding="utf-8")


# --------------------------------------------------------------------------------------------- semantic model
PG_TO_TMDL = {"text": "string", "int4": "int64", "int8": "int64", "numeric": "double", "float8": "double",
              "date": "dateTime", "timestamp": "dateTime"}
PG_TO_M = {"text": "type text", "int4": "Int64.Type", "int8": "Int64.Type", "numeric": "type number",
           "float8": "type number", "date": "type date", "timestamp": "type datetime"}
FORMATS = {"perf_index": "0.00", "median_index": "0.00", "vs_series_median": "0.0", "engagement_rate": "0.0%",
           "followers_change_pct": "0.00", "fans_per_1000_comments": "0.00", "uploads_per_month": "0.0",
           "likes_per_1k": "0.0", "comments_per_1k": "0.0", "shares_per_1k": "0.0", "saves_per_1k": "0.0",
           "views_per_day": "#,0", "likes_per_day": "#,0", "perf_per_day": "#,0", "median_views": "#,0",
           "neighbour_median": "#,0", "score": "0.0", "ndn_tiktok_index": "0.00", "ndn_youtube_index": "0.00",
           "followers_per_listener": "0.00"}
SORT_BY = {("dim_video", "published_weekday_ph"): "published_weekday_num",
           ("tiktok_video", "weekday_ph"): "weekday_num"}
TABLE_NOTES = {
    "dim_video": "One row per video on every platform, with real per-day measures (latest count / days since upload).",
    "account_daily": "One row per platform per day: followers and totals. data_source = real or synthetic.",
    "platform_daily": "Views and likes gained per platform per day, summed over videos.",
    "scorecard": "One row per platform: followers, change over the window, best post.",
    "tiktok_video": "One row per TikTok video: performance index (views / median of the 30 posted around it).",
    "tiktok_hashtag": "Hashtags used on 10 or more TikTok videos.",
    "insights": "Today's dashboard sentences, written at 15:00 PH by the Claude routine from that day's numbers.",
    "fan_demand": "Distinct fans asking NDN for an artist in YouTube + TikTok comments, last 12 months.",
    "fan_upload": "Artists whose sessions fans ask NDN to upload or put on streaming.",
    "bench_accounts": "Latest followers per benchmark account and platform, NDN included.",
    "bench_uploads": "Uploads of the last 12 months (older than 14 days): count and median views today.",
    "invite": "Who to invite to Live at The Cozy Cove: score 0-100, its six parts and the raw numbers (sql/025).",
    "dim_account": "One row per benchmark account and its region; filters both benchmark tables.",
}


def m_block(lines: list[str]) -> str:
    """Power Query text indented the way TMDL expects under `source =` (four tabs)."""
    return "\n".join("\t\t\t\t" + line for line in lines)


def csv_table(name: str, cols: list) -> str:
    out = [f"/// {TABLE_NOTES.get(name, name)}", f"table {name}", f"\tlineageTag: {tag(name)}", ""]
    for col, pg in cols:
        dt = PG_TO_TMDL[pg]
        out += [f"\tcolumn {col}", f"\t\tdataType: {dt}"]
        if pg == "date":
            out.append("\t\tformatString: yyyy-mm-dd")
        elif pg == "timestamp":
            out.append("\t\tformatString: yyyy-mm-dd hh:nn")
        elif dt in ("int64", "double"):
            out.append(f"\t\tformatString: {FORMATS.get(col, '#,0' if dt == 'int64' else '#,0.00')}")
        out += [f"\t\tlineageTag: {tag(name, col)}"]
        if dt != "string":
            out.append("\t\tsummarizeBy: none")
        if (name, col) in SORT_BY:
            out.append(f"\t\tsortByColumn: {SORT_BY[(name, col)]}")
        out += [f"\t\tsourceColumn: {col}", ""]
        if pg == "date":
            out += ["\t\tannotation UnderlyingDateTimeDataType = Date", ""]
        out += ["\t\tannotation SummarizationSetBy = User", ""]
    types = ", ".join(f'{{"{c}", {PG_TO_M[t]}}}' for c, t in cols)
    out += [f"\tpartition {name} = m", "\t\tmode: import", "\t\tsource =", m_block([
        "let",
        f'    Source = fnLoadCsv("{name}.csv"),',
        '    Nulls = Table.ReplaceValue(Source, "", null, Replacer.ReplaceValue, Table.ColumnNames(Source)),',
        f'    Typed = Table.TransformColumnTypes(Nulls, {{{types}}}, "en-US")',
        "in",
        "    Typed"]), ""]
    return "\n".join(out)


def platform_table() -> str:
    rows = ", ".join(f'{{"{p}", {i}, "{c}"}}' for i, (p, c) in enumerate(PLATFORMS.items(), 1))
    return "\n".join([
        "/// The three platforms; filters every per-platform table through relationships.",
        "table dim_platform", f"\tlineageTag: {tag('dim_platform')}", "",
        "\tcolumn platform", "\t\tdataType: string", f"\t\tlineageTag: {tag('dim_platform', 'platform')}",
        "\t\tsortByColumn: sort_order", "\t\tsourceColumn: platform", "",
        "\tcolumn sort_order", "\t\tdataType: int64", "\t\tisHidden", "\t\tformatString: 0",
        f"\t\tlineageTag: {tag('dim_platform', 'sort_order')}", "\t\tsummarizeBy: none", "\t\tsourceColumn: sort_order", "",
        "\tcolumn hex_color", "\t\tdataType: string", "\t\tisHidden", f"\t\tlineageTag: {tag('dim_platform', 'hex_color')}",
        "\t\tsourceColumn: hex_color", "",
        "\tpartition dim_platform = m", "\t\tmode: import", "\t\tsource =", m_block([
            "let",
            f"    Source = #table(type table [platform = text, sort_order = Int64.Type, hex_color = text], {{{rows}}})",
            "in",
            "    Source"]), ""])


MEASURES: list[tuple] = []          # (folder, name, dax, format or None, description)


def measure(folder, name, dax, fmt=None, desc=None):
    MEASURES.append((folder, name, dax.strip(), fmt, desc))


def on(p):        # filter to one platform through dim_platform
    return f'KEEPFILTERS ( dim_platform[platform] = "{p}" )'


def compact(var):
    """DAX that turns a number variable into 2.9M / 36.7K / 950."""
    return (f'IF ( ABS ( {var} ) >= 1000000, FORMAT ( {var} / 1000000, "0.0" ) & "M", '
            f'IF ( ABS ( {var} ) >= 1000, FORMAT ( {var} / 1000, "0.0" ) & "K", FORMAT ( {var}, "#,0" ) ) )')


def define_measures():
    # Overview: platform tiles from the scorecard, sparkline from real daily snapshots
    for p in PLATFORMS:
        measure("1 Overview", f"{p} Followers Text",
                f'FORMAT ( CALCULATE ( SUM ( scorecard[followers] ), {on(p)} ), "#,0" )')
        measure("1 Overview", f"{p} Change Text", f"""
VAR c = CALCULATE ( SUM ( scorecard[followers_change] ), {on(p)} )
VAR pct = CALCULATE ( SUM ( scorecard[followers_change_pct] ), {on(p)} ) / 100
VAR d = CALCULATE ( MAX ( scorecard[window_days] ), {on(p)} )
RETURN
    IF ( c = 0,
        "No visible change in " & d & " days",
        IF ( c > 0, "▲ ", "▼ " ) & FORMAT ( ABS ( c ), "#,0" ) & " (" & FORMAT ( ABS ( pct ), "0.0%" ) & ") in " & d & " days" )""",
                desc="Follower change over the scorecard window. YouTube rounds subscribers to 3 digits, so small changes show as none.")
        measure("1 Overview", f"{p} Gained Text", f"""
VAR g = CALCULATE ( SUM ( scorecard[metric_gained] ), {on(p)} )
VAR m = CALCULATE ( MAX ( scorecard[metric_name] ), {on(p)} )
VAR n = CALCULATE ( SUM ( scorecard[posts_in_window] ), {on(p)} )
RETURN "+" & {compact('g')} & " " & m & " gained · " & n & " new posts" """)
    measure("1 Overview", "Follower Growth %", """
VAR cur = CALCULATE ( SUM ( account_daily[followers] ), KEEPFILTERS ( account_daily[data_source] = "real" ) )
VAR firstDay = CALCULATE ( MIN ( account_daily[snapshot_date] ), ALLSELECTED ( account_daily[snapshot_date] ), account_daily[data_source] = "real" )
VAR base = CALCULATE ( SUM ( account_daily[followers] ), account_daily[snapshot_date] = firstDay, account_daily[data_source] = "real" )
RETURN IF ( NOT ISBLANK ( cur ), DIVIDE ( cur, base ) - 1 )""", "0.0%",
            "Followers vs the first real snapshot in the selected dates, per platform, so the three sizes share one axis.")
    measure("1 Overview", "Total Followers Text",
            'FORMAT ( SUM ( scorecard[followers] ), "#,0" ) & " followers on TikTok, YouTube and Instagram"')
    measure("1 Overview", "As Of Text",
            '"Data as of " & FORMAT ( MAX ( scorecard[as_of] ), "d mmm yyyy" ) & " · daily snapshots at 9 am PH"')
    for slot, label in [("summary_headline", "Headline"), ("action_1", "Action 1"), ("action_2", "Action 2"),
                        ("action_3", "Action 3"), ("audience_headline", "Audience"),
                        ("sessions_headline", "Sessions"), ("upload_headline", "Uploads")]:
        measure("1 Overview", f"Insight {label}", f'CALCULATE ( MAX ( insights[sentence] ), insights[slot] = "{slot}" )')
    measure("1 Overview", "Insights Note",
            '"Written " & FORMAT ( MAX ( insights[as_of] ), "d mmm yyyy" ) & " at 3 pm PH by a Claude routine, from that day\'s numbers only"')
    measure("1 Overview", "Best Post Gained", "SUM ( scorecard[best_post_gained] )", "#,0")

    # TikTok
    measure("2 TikTok", "TikTok videos", "COUNTROWS ( tiktok_video )", "#,0")
    measure("2 TikTok", "Median views per TikTok", "MEDIAN ( tiktok_video[views] )", "#,0")
    measure("2 TikTok", "Median Index", "MEDIAN ( tiktok_video[perf_index] )", "0.00",
            "Median performance index: views / median views of the 30 NDN TikToks posted around it. 1.00 = typical.")
    measure("2 TikTok", "Breakouts, all time", """
DIVIDE (
    CALCULATE ( COUNTROWS ( tiktok_video ), KEEPFILTERS ( tiktok_video[perf_index] >= 2 ) ),
    CALCULATE ( COUNTROWS ( tiktok_video ), KEEPFILTERS ( NOT ISBLANK ( tiktok_video[perf_index] ) ) ) )""",
            "0%", "Share of TikToks with at least twice the views of the typical post around them.")
    measure("2 TikTok", "Breakouts, last 30 days",
            'CALCULATE ( [Breakouts, all time], KEEPFILTERS ( tiktok_video[is_last_30d] = "yes" ) )', "0%")
    measure("2 TikTok", "TikTok Views 30d",
            'CALCULATE ( SUM ( tiktok_video[views] ), KEEPFILTERS ( tiktok_video[is_last_30d] = "yes" ) )', "#,0")
    measure("2 TikTok", "TikTok Index 30d",
            'CALCULATE ( MAX ( tiktok_video[perf_index] ), KEEPFILTERS ( tiktok_video[is_last_30d] = "yes" ) )', "0.00")

    # YouTube and Instagram: real per-day measures from dim_video
    yt, ig = on("YouTube"), on("Instagram")
    measure("3 YouTube", "YouTube videos", f"CALCULATE ( COUNTROWS ( dim_video ), {yt} )", "#,0")
    measure("3 YouTube", "YouTube Median Views/Day", f"CALCULATE ( MEDIAN ( dim_video[views_per_day] ), {yt} )", "#,0",
            "Median of latest views / days since upload.")
    measure("3 YouTube", "Median views/day, full sessions",
            f'CALCULATE ( MEDIAN ( dim_video[views_per_day] ), {yt}, KEEPFILTERS ( dim_video[video_format] = "Full video" ) )', "#,0")
    measure("3 YouTube", "Median views/day, Shorts",
            f'CALCULATE ( MEDIAN ( dim_video[views_per_day] ), {yt}, KEEPFILTERS ( dim_video[video_format] = "Short (<=60 s)" ) )', "#,0")
    measure("3 YouTube", "YouTube views gained, last 7 days",
            f"CALCULATE ( SUM ( scorecard[metric_gained] ), {yt} )", "#,0")
    measure("3 YouTube", "YouTube Views Gained Real",
            f'CALCULATE ( SUM ( platform_daily[views_gained] ), {yt}, KEEPFILTERS ( platform_daily[data_source] = "real" ) )', "#,0")
    measure("3 YouTube", "YouTube Views/Day 90d",
            f"CALCULATE ( SUM ( dim_video[views_per_day] ), {yt}, KEEPFILTERS ( dim_video[age_days] <= 90 ) )", "#,0")
    measure("3 YouTube", "YouTube vs Series 90d",
            f"CALCULATE ( MAX ( dim_video[vs_series_median] ), {yt}, KEEPFILTERS ( dim_video[age_days] <= 90 ) )", "0.0")
    measure("3 YouTube", "YouTube Artist Views/Day", f"CALCULATE ( SUM ( dim_video[views_per_day] ), {yt} )", "#,0")
    measure("3 YouTube", "YouTube Artist Views/Day Top 10", """
VAR r = RANKX ( FILTER ( ALLSELECTED ( dim_video[artist] ), NOT ISBLANK ( dim_video[artist] ) ), [YouTube Artist Views/Day] )
RETURN IF ( NOT ISBLANK ( SELECTEDVALUE ( dim_video[artist] ) ) && r <= 10, [YouTube Artist Views/Day] )""", "#,0")

    measure("4 Instagram", "Instagram posts", f"CALCULATE ( COUNTROWS ( dim_video ), {ig} )", "#,0")
    measure("4 Instagram", "Median likes/day, all posts", f"CALCULATE ( MEDIAN ( dim_video[likes_per_day] ), {ig} )", "#,0")
    measure("4 Instagram", "Median views/day, Reels",
            f'CALCULATE ( MEDIAN ( dim_video[views_per_day] ), {ig}, KEEPFILTERS ( dim_video[video_format] = "Instagram Reel" ) )', "#,0")
    measure("4 Instagram", "Instagram likes gained, last 6 days", f"CALCULATE ( SUM ( scorecard[metric_gained] ), {ig} )", "#,0")
    measure("4 Instagram", "Instagram Likes Gained Real",
            f'CALCULATE ( SUM ( platform_daily[likes_gained] ), {ig}, KEEPFILTERS ( platform_daily[data_source] = "real" ) )', "#,0")
    measure("4 Instagram", "Instagram Likes/Day 90d",
            f"CALCULATE ( SUM ( dim_video[likes_per_day] ), {ig}, KEEPFILTERS ( dim_video[age_days] <= 90 ) )", "#,0")
    measure("4 Instagram", "Instagram Views/Day 90d",
            f"CALCULATE ( SUM ( dim_video[views_per_day] ), {ig}, KEEPFILTERS ( dim_video[age_days] <= 90 ) )", "#,0")

    # Question charts (TIKTOK/YOUTUBE/INSTAGRAM_QUESTIONS.md)
    tt = "2 TikTok"
    measure(tt, "Breakout share", """
DIVIDE (
    CALCULATE ( COUNTROWS ( tiktok_video ), KEEPFILTERS ( tiktok_video[perf_index] >= 2 ) ),
    CALCULATE ( COUNTROWS ( tiktok_video ), KEEPFILTERS ( NOT ISBLANK ( tiktok_video[perf_index] ) ) ) )""", "0%")
    measure(tt, "Median shares+saves per 1k", "MEDIAN ( tiktok_video[share_save_per_1k] )", "0.0")
    measure(tt, "Median comments per 1k", "MEDIAN ( tiktok_video[comments_per_1k] )", "0.0")
    measure(tt, "Median 7-day views gained", "MEDIAN ( tiktok_video[views_gained_7d] )", "#,0")
    measure(tt, "Median 7-day gain per 1k, older posts",
            "CALCULATE ( MEDIAN ( tiktok_video[gained_7d_per_1k] ), KEEPFILTERS ( tiktok_video[age_days] > 30 ) )", "0.00",
            "Views gained in the last 7 days per 1,000 views so far, videos older than 30 days.")
    measure(tt, "Videos made with NDN sounds", "SUM ( tiktok_video[sound_uses] )", "#,0",
            "Videos by anyone on TikTok that use the sound of an NDN post (sound page count, latest week).")
    measure(tt, "Shares+saves per 1k", "MAX ( tiktok_video[share_save_per_1k] )", "0.0")
    measure(tt, "Sound uses", "SUM ( tiktok_video[sound_uses] )", "#,0")
    measure(tt, "TikTok Artist Index Top 10", """
VAR r = RANKX ( FILTER ( ALLSELECTED ( tiktok_video[artist] ),
            NOT ISBLANK ( tiktok_video[artist] ) && CALCULATE ( COUNTROWS ( tiktok_video ) ) >= 3 ), [Median Index] )
RETURN IF ( NOT ISBLANK ( SELECTEDVALUE ( tiktok_video[artist] ) ) && COUNTROWS ( tiktok_video ) >= 3 && r <= 10, [Median Index] )""",
            "0.00")
    yt3 = "3 YouTube"
    full = 'KEEPFILTERS ( dim_video[video_format] = "Full video" )'
    measure(yt3, "YouTube engagement rate", f"CALCULATE ( MEDIAN ( dim_video[engagement_rate] ), {yt} )", "0.00%",
            "Median (likes + comments) / views.")
    measure(yt3, "YouTube median 7-day gain", f"CALCULATE ( MEDIAN ( dim_video[views_gained_7d] ), {yt} )", "#,0")
    measure(yt3, "YouTube 7-day gain, older sessions",
            f"CALCULATE ( SUM ( dim_video[views_gained_7d] ), {yt}, KEEPFILTERS ( dim_video[age_days] >= 365 ) )", "#,0")
    measure(yt3, "YouTube views per day", f"CALCULATE ( SUM ( dim_video[views_per_day] ), {yt}, {full} )", "#,0")
    measure(yt3, "YouTube artist listeners", f"CALCULATE ( MAX ( dim_video[artist_monthly_listeners] ), {yt}, {full} )", "#,0")
    measure(yt3, "YouTube song Spotify streams", f"CALCULATE ( MAX ( dim_video[song_spotify_streams] ), {yt}, {full} )", "#,0")
    measure(yt3, "Sessions", "COUNTROWS ( yt_heatmap )", "#,0")
    measure(yt3, "Searches", "COUNTROWS ( yt_search )", "#,0")
    ig4 = "4 Instagram"
    reel = 'KEEPFILTERS ( dim_video[video_format] = "Instagram Reel" )'
    measure(ig4, "Reel views per day", f"CALCULATE ( SUM ( dim_video[views_per_day] ), {ig}, {reel} )", "#,0")
    measure(ig4, "Reel artist listeners", f"CALCULATE ( MAX ( dim_video[artist_monthly_listeners] ), {ig}, {reel} )", "#,0")
    measure(ig4, "Median reposts per 1k views", f"CALCULATE ( MEDIAN ( dim_video[reposts_per_1k_views] ), {ig} )", "0.00")
    measure(ig4, "Median comments per 1k likes", f"CALCULATE ( MEDIAN ( dim_video[comments_per_1k_likes] ), {ig} )", "0.0")
    measure(ig4, "Instagram median 7-day likes gained", f"CALCULATE ( MEDIAN ( dim_video[likes_gained_7d] ), {ig} )", "#,0")
    measure(ig4, "Song YouTube views", "SUM ( song_compare[youtube_views] )", "#,0")
    measure(ig4, "Song Instagram likes", "SUM ( song_compare[instagram_likes] )", "#,0")

    # Benchmarks: one measure per platform so each small chart needs no visual filter
    for p in PLATFORMS:
        measure("5 Benchmarks", f"Followers {p}",
                f'CALCULATE ( SUM ( bench_accounts[followers] ), KEEPFILTERS ( bench_accounts[platform] = "{p}" ) )', "#,0")
        measure("5 Benchmarks", f"Median Views {p}",
                f'CALCULATE ( SUM ( bench_uploads[median_views] ), KEEPFILTERS ( bench_uploads[platform] = "{p}" ) )', "#,0")
        measure("5 Benchmarks", f"Uploads/Month {p}",
                f'CALCULATE ( SUM ( bench_uploads[uploads_per_month] ), KEEPFILTERS ( bench_uploads[platform] = "{p}" ) )', "0.0")
    measure("5 Benchmarks", "Is NDN Account", 'IF ( SELECTEDVALUE ( bench_accounts[region] ) = "ndn", 1, 0 )', "0")
    measure("5 Benchmarks", "Is NDN Uploads", 'IF ( SELECTEDVALUE ( bench_uploads[region] ) = "ndn", 1, 0 )', "0")

    # Community
    measure("7 Community", "Artists fans ask for", "COUNTROWS ( fan_demand )", "#,0")
    measure("7 Community", "Never on NDN",
            'CALCULATE ( COUNTROWS ( fan_demand ), KEEPFILTERS ( fan_demand[status] = "Never on NDN" ) )', "#,0")
    measure("7 Community", "Artists with upload requests", "COUNTROWS ( fan_upload )", "#,0")
    measure("7 Community", "Fans Asking", "SUM ( fan_demand[fans] )", "#,0")
    measure("7 Community", "Fans Asking Top 15", """
VAR r = RANKX ( ALLSELECTED ( fan_demand[artist] ), [Fans Asking] )
RETURN IF ( r <= 15, [Fans Asking] )""", "#,0")
    measure("7 Community", "Is Never Played", 'IF ( SELECTEDVALUE ( fan_demand[status] ) = "Never on NDN", 1, 0 )', "0")

    # Invite: rank inside whatever the page filters leave, so the top 10 follows the filters
    for status, pre in [("Recommend", "Inv"), ("Not now", "Not"), ("Cooling down", "Cool")]:
        keep = f'KEEPFILTERS ( invite[status] = "{status}" )'
        measure("2 Invite", f"{pre} Score Raw", f"CALCULATE ( SUM ( invite[score] ), {keep} )", "0.0")
        measure("2 Invite", f"{pre} Rank Raw", f"""
IF ( NOT ISBLANK ( [{pre} Score Raw] ),
    RANKX ( FILTER ( ALLSELECTED ( invite[artist] ), NOT ISBLANK ( [{pre} Score Raw] ) ), [{pre} Score Raw] ) )""", "0")
        measure("2 Invite", f"{pre} Rank", f"IF ( [{pre} Rank Raw] <= 10, [{pre} Rank Raw] )", "0")
        for c, agg, fmt in INVITE_COLUMNS:
            measure("2 Invite", f"{pre} {c}",
                    f"IF ( [{pre} Rank Raw] <= 10, CALCULATE ( {agg} ( invite[{c}] ), {keep} ) )", fmt)
        for c in INVITE_TEXT:
            measure("2 Invite", f"{pre} {c}",
                    f"IF ( [{pre} Rank Raw] <= 10, CALCULATE ( SELECTEDVALUE ( invite[{c}] ), {keep} ) )")
    measure("2 Invite", "Artists scored", "COUNTROWS ( invite )", "#,0")
    measure("2 Invite", "Recommended now", 'CALCULATE ( COUNTROWS ( invite ), KEEPFILTERS ( invite[status] = "Recommend" ) )', "#,0")
    measure("2 Invite", "Not now", 'CALCULATE ( COUNTROWS ( invite ), KEEPFILTERS ( invite[status] = "Not now" ) )', "#,0",
            "Good artists whose current hit is already on NDN's YouTube, or who have no new hit since their last visit.")
    measure("2 Invite", "Cooling down now",
            'CALCULATE ( COUNTROWS ( invite ), KEEPFILTERS ( invite[status] = "Cooling down" ) )', "#,0",
            "Played for NDN in the last 10 months, so not recommended again yet.")


# invite columns shown in the tables: (column, DAX aggregate, format)
INVITE_TEXT = ["ndn_history", "new_hit", "top_song", "top_song_on_ndn", "hit_status"]
INVITE_COLUMNS = [("score", "SUM", "0.0"), ("new_hit_hype", "SUM", "0"), ("new_hit_daily_streams", "SUM", "#,0"),
                  ("new_hit_released", "MAX", "yyyy-mm-dd"), ("top_song_daily_streams", "SUM", "#,0"), ("momentum", "SUM", "0"), ("local_reach", "SUM", "0"),
                  ("fan_demand", "SUM", "0"), ("track_record", "SUM", "0"), ("size", "SUM", "0"), ("loyalty", "SUM", "0"),
                  ("monthly_listeners", "SUM", "#,0"), ("spotify_followers", "SUM", "#,0"),
                  ("manila_baguio_listeners", "SUM", "#,0"), ("best_chart_rank", "MIN", "0"),
                  ("weeks_on_chart", "MAX", "0"), ("tiktok_followers", "SUM", "#,0"), ("tiktok_asks", "SUM", "#,0"),
                  ("fans_asking", "SUM", "#,0"), ("ndn_youtube_videos", "SUM", "#,0"), ("ndn_tiktok_clips", "SUM", "#,0"),
                  ("last_ndn_post", "MAX", "yyyy-mm-dd"), ("cooldown_until", "MAX", "yyyy-mm-dd")]


def measures_table() -> str:
    out = ["/// Holds every DAX measure; the placeholder column is hidden.", "table _Measures",
           f"\tlineageTag: {tag('_Measures')}", ""]
    for folder, name, dax, fmt, desc in MEASURES:
        if desc:
            out.append(f"\t/// {desc}")
        lines = dax.splitlines()
        if len(lines) == 1:
            out.append(f"\tmeasure '{name}' = {lines[0]}")
        else:
            out.append(f"\tmeasure '{name}' =")
            out += [f"\t\t\t{line}" for line in lines]
        if fmt:
            out.append(f"\t\tformatString: {fmt}")
        out += [f"\t\tdisplayFolder: {folder}", f"\t\tlineageTag: {tag('_Measures', name)}", ""]
    out += ["\tcolumn placeholder", "\t\tdataType: int64", "\t\tisHidden", "\t\tformatString: 0",
            f"\t\tlineageTag: {tag('_Measures', 'placeholder')}", "\t\tsummarizeBy: none", "\t\tsourceColumn: placeholder", "",
            "\t\tannotation SummarizationSetBy = User", "",
            "\tpartition _Measures = m", "\t\tmode: import", "\t\tsource =",
            m_block(["let", '    Source = #table(type table [placeholder = Int64.Type], {{1}})', "in", "    Source"]), ""]
    return "\n".join(out)


def build_model(schema: dict) -> None:
    d = MODEL / "definition"
    if d.exists():
        clear(d)
    (d / "tables").mkdir(parents=True)
    (d / "cultures").mkdir()
    write_json(MODEL / "definition.pbism", {"$schema": f"{SCHEMA}/item/semanticModel/definitionProperties/1.0.0/schema.json",
                                            "version": "4.2", "settings": {}})
    write_json(MODEL / ".platform", {
        "$schema": f"{SCHEMA}/gitIntegration/platformProperties/2.0.0/schema.json",
        "metadata": {"type": "SemanticModel", "displayName": NAME},
        "config": {"version": "2.0", "logicalId": tag("model")}})
    tables = ["dim_platform", *schema, "_Measures"]
    (d / "database.tmdl").write_text("database\n\tcompatibilityLevel: 1606\n", encoding="utf-8")
    (d / "model.tmdl").write_text("\n".join([
        "model Model", "\tculture: en-US", "\tdefaultPowerBIDataSourceVersion: powerBI_V3",
        "\tsourceQueryCulture: en-US", "\tdataAccessOptions", "\t\tlegacyRedirects", "\t\treturnErrorValuesAsNull", "",
        "annotation __PBI_TimeIntelligenceEnabled = 0", "",
        *[f"ref table {t}" for t in tables], "", "ref cultureInfo en-US", ""]), encoding="utf-8")
    (d / "cultures" / "en-US.tmdl").write_text("cultureInfo en-US\n", encoding="utf-8")
    folder = str(DATA).replace('"', '""')
    (d / "expressions.tmdl").write_text("\n".join([
        "/// Folder holding the CSVs from export_powerbi.py. Change this one value to repoint the whole model.",
        f'expression DataFolder = "{folder}"', f"\tlineageTag: {tag('DataFolder')}", "",
        "/// Loads one CSV from DataFolder (UTF-8, header row).",
        "expression fnLoadCsv =",
        "\t\tlet",
        "\t\t    fn = (fileName as text) as table =>",
        "\t\t        let",
        '\t\t            Source = Csv.Document(File.Contents(DataFolder & "\\" & fileName), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),',
        "\t\t            Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true])",
        "\t\t        in",
        "\t\t            Promoted",
        "\t\tin",
        "\t\t    fn",
        f"\tlineageTag: {tag('fnLoadCsv')}", ""]), encoding="utf-8")
    (d / "tables" / "dim_platform.tmdl").write_text(platform_table(), encoding="utf-8")
    for name, cols in schema.items():
        (d / "tables" / f"{name}.tmdl").write_text(csv_table(name, cols), encoding="utf-8")
    define_measures()
    (d / "tables" / "_Measures.tmdl").write_text(measures_table(), encoding="utf-8")
    rels = []
    for t in ["dim_video", "account_daily", "platform_daily", "scorecard"]:
        rels += [f"relationship {t}_to_platform", f"\tfromColumn: {t}.platform", "\ttoColumn: dim_platform.platform", ""]
    for t in ["bench_accounts", "bench_uploads"]:
        rels += [f"relationship {t}_to_account", f"\tfromColumn: {t}.account", "\ttoColumn: dim_account.account", ""]
    (d / "relationships.tmdl").write_text("\n".join(rels), encoding="utf-8")


# --------------------------------------------------------------------------------------------- report helpers
def lit(v):
    return {"expr": {"Literal": {"Value": v}}}


def s(text):                       # string literal; single quotes doubled
    return lit("'" + str(text).replace("'", "''") + "'")


def b(v):
    return lit("true" if v else "false")


def n(v):
    return lit(f"{v}D")


def color(hexv):
    return {"solid": {"color": s(hexv)}}


def props(**kw):
    return [{"properties": kw}]


def col(entity, prop):
    return {"Column": {"Expression": {"SourceRef": {"Entity": entity}}, "Property": prop}}


def meas(prop):
    return {"Measure": {"Expression": {"SourceRef": {"Entity": "_Measures"}}, "Property": prop}}


def proj(field, active=False, label=None):
    kind = "Column" if "Column" in field else "Measure"
    ent, prop = field[kind]["Expression"]["SourceRef"]["Entity"], field[kind]["Property"]
    p = {"field": field, "queryRef": f"{ent}.{prop}", "nativeQueryRef": prop}
    if active:
        p["active"] = True
    if label:
        p["displayName"] = label
    return p


def frame(title=None, subtitle=None, bg=True, border=True, alt="", pad=None):
    """The box around a visual: card colour, thin border, question title and one-line subtitle."""
    o = {"background": props(show=b(bg), color=color(CARD), transparency=n(0)),
         "border": props(show=b(border), color=color(LINE), radius=n(10)),
         "dropShadow": props(show=b(False)), "visualHeader": props(show=b(False)),
         "general": props(altText=s(alt or title or "decorative"))}
    if title:
        o["title"] = props(show=b(True), text=s(title), fontSize=n(12), fontFamily=s("Segoe UI Semibold"),
                           fontColor=color(INK), alignment=s("left"), background=color(CARD))
    else:
        o["title"] = props(show=b(False))
    if subtitle:
        o["subTitle"] = props(show=b(True), text=s(subtitle), fontSize=n(9), fontFamily=s("Segoe UI"),
                              fontColor=color(INK3), alignment=s("left"))
    if pad is not None:
        o["padding"] = props(top=n(pad), left=n(pad), right=n(pad), bottom=n(pad))
    return o


def cases(measure_name, rules):
    """Conditional fill: rules = [(comparison kind, value, colour)]; kinds 0 =, 1 >, 2 >=, 3 <, 4 <=."""
    return [{"properties": {"fill": {"solid": {"color": {"expr": {"Conditional": {"Cases": [
        {"Condition": {"Comparison": {"ComparisonKind": k, "Left": meas(measure_name), "Right": {"Literal": {"Value": f"{v}D"}}}},
         "Value": {"Literal": {"Value": f"'{c}'"}}} for k, v, c in rules]}}}}}},
        "selector": {"data": [{"dataViewWildcard": {"matchingOption": 1}}]}}]


def one_fill(hexv):
    return [{"properties": {"fill": color(hexv)}, "selector": {"data": [{"dataViewWildcard": {"matchingOption": 1}}]}}]


def grid(n, x0=30, width=1540, gap=20):
    """n equal columns across the full content width: [(x, w), ...]."""
    w = (width - gap * (n - 1)) / n
    return [(round(x0 + i * (w + gap)), round(w)) for i in range(n)]


ROW = 340                                     # row step: 320 px visual + 20 px gap


class Page:
    """One report page. Visuals placed at y >= 110 move down by SHIFT to make room for the filter row."""

    def __init__(self, pid, display, height, option="FitToWidth"):
        self.pid, self.display, self.option = pid, display, option
        self.height = height + SHIFT
        self.visuals, self.z = [], 1000

    def add(self, key, vtype, x, y, w, h, query=None, objects=None, vco=None, sort=None, extra=None, absolute=False):
        if not absolute and y >= 110:
            y += SHIFT
        name = f"{self.pid}_{key}"
        v = {"visualType": vtype}
        if query:
            v["query"] = {"queryState": query}
            if sort:
                v["query"]["sortDefinition"] = {"sort": sort, "isDefaultSort": True}
        if objects:
            v["objects"] = objects
        v["visualContainerObjects"] = vco or frame(bg=False, border=False)
        v["drillFilterOtherVisuals"] = True
        self.visuals.append({"$schema": VC_SCHEMA, "name": name,
                             "position": {"x": x, "y": y, "z": self.z, "height": h, "width": w, "tabOrder": self.z},
                             "visual": v, **(extra or {})})
        self.z += 1000

    # ---- building blocks
    def text(self, key, x, y, w, h, paragraphs, bg=False, border=False, center=False, absolute=False):
        paras = []
        for runs in paragraphs:
            p = {"textRuns": [{"value": t, "textStyle": {"fontFamily": "Segoe UI", **st}} for t, st in runs]}
            if center:
                p["horizontalTextAlignment"] = "center"
            paras.append(p)
        self.add(key, "textbox", x, y, w, h, objects={"general": props(paragraphs=paras)}, absolute=absolute,
                 vco={"background": props(show=b(bg), color=color(CARD), transparency=n(0)),
                      "border": props(show=b(border), color=color(LINE), radius=n(10)),
                      "dropShadow": props(show=b(False)), "visualHeader": props(show=b(False))})

    def card(self, key, x, y, w, h, m, size=12, ink=INK, font="Segoe UI", wrap=False, label=False, boxed=False,
             alt="", absolute=False):
        objects = {"labels": props(color=color(ink), fontSize=n(size), fontFamily=s(font)),
                   "categoryLabels": props(show=b(label), color=color(INK3), fontSize=n(9), fontFamily=s("Segoe UI")),
                   "wordWrap": props(show=b(wrap))}
        vco = frame(bg=boxed, border=boxed, alt=alt or m, pad=0 if not boxed else None)
        self.add(key, "card", x, y, w, h, query={"Values": {"projections": [proj(meas(m))]}}, objects=objects,
                 vco=vco, absolute=absolute)

    def kpi(self, key, x, y, w, m):
        self.card(key, x, y, w, 90, m, size=22, font="Segoe UI Semibold", label=True, boxed=True)

    def bars(self, key, vtype, x, y, w, h, cat, m, title, subtitle, fill, sort_by_value=True):
        objects = {
            "categoryAxis": props(show=b(True), showAxisTitle=b(False), fontSize=n(9), fontFamily=s("Segoe UI"),
                                  labelColor=color(INK2), gridlineShow=b(False)),
            "valueAxis": props(show=b(False), showAxisTitle=b(False), gridlineShow=b(False)),
            "legend": props(show=b(False)),
            "labels": props(show=b(True), fontSize=n(9), fontFamily=s("Segoe UI"), color=color(INK),
                            labelDisplayUnits=n(0)),
            "dataPoint": fill}
        sort = [{"field": meas(m), "direction": "Descending"}] if sort_by_value else [{"field": cat, "direction": "Ascending"}]
        self.add(key, vtype, x, y, w, h,
                 query={"Category": {"projections": [proj(cat, active=True)]}, "Y": {"projections": [proj(meas(m))]}},
                 objects=objects, vco=frame(title, subtitle), sort=sort)

    def line(self, key, x, y, w, h, cat, m, title, subtitle, hexv=None, series=None, series_colors=None):
        objects = {
            "categoryAxis": props(show=b(True), showAxisTitle=b(False), fontSize=n(9), labelColor=color(INK3),
                                  gridlineShow=b(False)),
            "valueAxis": props(show=b(True), showAxisTitle=b(False), fontSize=n(9), labelColor=color(INK3),
                               gridlineShow=b(True), gridlineColor=color(GRID)),
            "legend": props(show=b(series is not None), position=s("Top"), labelColor=color(INK2), fontSize=n(10)),
            "labels": props(show=b(False)),
            "lineStyles": props(strokeWidth=lit("2L"), showMarker=b(True))}
        query = {"Category": {"projections": [proj(cat, active=True)]}, "Y": {"projections": [proj(meas(m))]}}
        if series is not None:
            query["Series"] = {"projections": [proj(series)]}
            ent, prop = series["Column"]["Expression"]["SourceRef"]["Entity"], series["Column"]["Property"]
            objects["dataPoint"] = [{"properties": {"fill": color(c)}, "selector": {"data": [{"scopeId": {"Comparison": {
                "ComparisonKind": 0, "Left": col(ent, prop), "Right": {"Literal": {"Value": f"'{v}'"}}}}}]}}
                for v, c in series_colors.items()]
        else:
            objects["dataPoint"] = props(defaultColor=color(hexv))
        self.add(key, "lineChart", x, y, w, h, query=query, objects=objects, vco=frame(title, subtitle),
                 sort=[{"field": cat, "direction": "Ascending"}])

    def table(self, key, x, y, w, h, fields, title, subtitle, sort_field, direction="Descending", bars=()):
        """bars: measure names drawn as data bars behind their numbers (the score parts on the Invite page)."""
        objects = None
        if bars:
            objects = {"columnFormatting": [
                {"properties": {"dataBars": {
                    "positiveColor": color(GOLD if i == 0 else BAR_DIM), "negativeColor": color(LO),
                    "axisColor": color(LINE), "reverseDirection": b(False), "hideText": b(False)}},
                 "selector": {"metadata": f"_Measures.{m}"}} for i, m in enumerate(bars)]}
        self.add(key, "tableEx", x, y, w, h,
                 query={"Values": {"projections": [proj(f, label=lab) for f, lab in fields]}}, objects=objects,
                 vco=frame(title, subtitle), sort=[{"field": sort_field, "direction": direction}])

    def scatter(self, key, x, y, w, h, cat, mx, my, title, subtitle, hexv):
        """One dot per item; both axes log scale because views and listeners span 1,000x."""
        objects = {
            "categoryAxis": props(show=b(True), showAxisTitle=b(True), axisScale=s("log"), fontSize=n(9),
                                  labelColor=color(INK3), titleColor=color(INK3), gridlineShow=b(False)),
            "valueAxis": props(show=b(True), showAxisTitle=b(True), axisScale=s("log"), fontSize=n(9),
                               labelColor=color(INK3), titleColor=color(INK3), gridlineShow=b(True),
                               gridlineColor=color(GRID)),
            "legend": props(show=b(False)),
            "dataPoint": one_fill(hexv)}
        self.add(key, "scatterChart", x, y, w, h, objects=objects, vco=frame(title, subtitle),
                 query={"Category": {"projections": [proj(cat, active=True)]},
                        "X": {"projections": [proj(meas(mx))]}, "Y": {"projections": [proj(meas(my))]}})

    def note(self, key, x, y, w, h, title, items):
        """A boxed list of questions the public data can't answer yet, so no question is silently dropped."""
        paras = [[(title, {"fontWeight": "bold", "fontSize": "12pt", "color": GOLD, "fontFamily": TITLE_FONT})]]
        for q, why in items:
            paras.append([(q + "  ", {"fontWeight": "bold", "fontSize": "9pt", "color": INK}),
                          (why, {"fontSize": "9pt", "color": INK2})])
        self.text(key, x, y, w, h, paras, bg=True, border=True)

    # ---- page furniture
    def header(self, title, question):
        self.text("hdr", 30, 14, 840, 92, [
            [("NINE DEGREES NORTH · SOCIAL MEDIA DASHBOARD", {"fontWeight": "bold", "fontSize": "8pt", "color": INK3})],
            [(title, {"fontWeight": "bold", "fontSize": "20pt", "color": GOLD, "fontFamily": TITLE_FONT})],
            [(question, {"fontSize": "10pt", "color": INK2})]])
        self.add("nav", "pageNavigator", 880, 26, 690, 34,
                 vco={"border": props(show=b(False)), "background": props(show=b(False)),
                      "dropShadow": props(show=b(False)),
                      "general": props(altText=s("Page navigation between the seven pages"))},
                 extra={"howCreated": "InsertVisualButton"})
        self.card("asof", 880, 66, 690, 24, "As Of Text", size=9, ink=INK3)

    def filters(self, slicers):
        """Filter row under the header: [(column field, label, 'Dropdown' or 'Between')], then a Reset button."""
        for i, (field, label, mode) in enumerate(slicers):
            objects = {"data": props(mode=s(mode)),
                       "header": props(show=b(False), text=s(label)),
                       "items": props(fontFamily=s("Segoe UI"), fontColor=color(INK), background=color(CARD)),
                       "general": [{"properties": {}}],
                       "pendingChangesIcon": props(show=b(False))}
            if mode == "Between":
                objects["slider"] = props(show=b(False))
                objects["date"] = props(textSize=n(9))
            vco = frame(alt=f"{label} filter, this page only")
            vco["title"] = props(show=b(True), text=s(label), fontSize=n(9), fontFamily=s("Segoe UI"),
                                 fontColor=color(INK3), alignment=s("left"), background=color(CARD))
            vco["spacing"] = props(spaceAbovePlotArea=n(0))
            self.add(f"f{i}", "slicer", 30 + i * 300, 112, 285, 58, absolute=True, objects=objects, vco=vco,
                     query={"Values": {"projections": [proj(field, active=True)]}})
        self.add("reset", "actionButton", 1430, 120, 140, 42, absolute=True,
                 objects={"icon": [{"properties": {"shapeType": s("reset"), "lineColor": color(GOLD)},
                                    "selector": {"id": "default"}}],
                          "text": [{"properties": {"show": b(True), "text": s("Reset filters"), "fontColor": color(INK),
                                                   "fontSize": n(10)}, "selector": {"id": "default"}}],
                          "fill": [{"properties": {"show": b(True), "fillColor": color(CARD)}, "selector": {"id": "default"}}],
                          "outline": [{"properties": {"show": b(True), "lineColor": color(GOLD)}, "selector": {"id": "default"}}]},
                 vco={"visualLink": props(show=b(True), type=s("ClearAllSlicers")),
                      "general": props(altText=s("Reset: clears every filter on this page")),
                      "dropShadow": props(show=b(False)), "visualHeader": props(show=b(False))},
                 extra={"howCreated": "InsertVisualButton"})

    def footer(self, note=None):
        if note:
            self.text("note", 30, self.height - 62, 1540, 26, [[(note, {"fontSize": "8pt", "color": INK2})]], absolute=True)
        self.text("foot", 30, self.height - 34, 1540, 26, [[(DISCLAIMER, {"fontSize": "8pt", "color": INK3})]],
                  absolute=True)


# --------------------------------------------------------------------------------------------- pages
def overview() -> Page:
    pg = Page("ov", "Overview", 1060, "FitToWidth")
    pg.header("Overview", "How are NDN's three channels doing this week, and what should the team do next?")
    pg.filters([(col("dim_platform", "platform"), "Platform", "Dropdown"),
                (col("account_daily", "snapshot_date"), "Dates (follower chart)", "Between")])
    notes = {"TikTok": "followers", "YouTube": "subscribers (YouTube rounds to 3 digits)", "Instagram": "followers"}
    for i, (p, hexv) in enumerate(PLATFORMS.items()):
        x, y, w = 30 + i * 523, 112, 494
        pg.text(f"tile_{p}", x, y, w, 150, [
            [(p.upper(), {"fontWeight": "bold", "fontSize": "10pt", "color": hexv})],
            [(notes[p], {"fontSize": "8pt", "color": INK3})]], bg=True, border=True)
        pg.card(f"val_{p}", x + 12, y + 46, w - 24, 42, f"{p} Followers Text", size=24, font="Segoe UI Semibold")
        pg.card(f"chg_{p}", x + 12, y + 92, w - 24, 22, f"{p} Change Text", size=10, ink=INK2)
        pg.card(f"gain_{p}", x + 12, y + 116, w - 24, 22, f"{p} Gained Text", size=10, ink=INK3)
    pg.line("growth", 30, 282, 1010, 300, col("account_daily", "snapshot_date"), "Follower Growth %",
            "Grow: which channel is gaining followers fastest?",
            "Growth since the first real snapshot in the selected dates. % keeps the three sizes on one axis",
            series=col("dim_platform", "platform"), series_colors=PLATFORMS)
    pg.table("best", 1060, 282, 510, 300,
             [(col("scorecard", "platform"), "Platform"), (meas("Best Post Gained"), "Gained"),
              (col("scorecard", "best_post"), "Best post")],
             "Best post this week on each platform",
             "Views gained over the scorecard window (likes on Instagram)", meas("Best Post Gained"))
    y0 = 602
    pg.text("ins_box", 30, y0, 1540, 440, [
        [("What the numbers say today", {"fontWeight": "bold", "fontSize": "13pt", "color": GOLD,
                                         "fontFamily": TITLE_FONT})]], bg=True, border=True)
    pg.card("ins_note", 42, y0 + 36, 1516, 20, "Insights Note", size=9, ink=INK3)
    pg.card("ins_head", 42, y0 + 62, 1516, 50, "Insight Headline", size=13, font="Segoe UI Semibold", wrap=True)
    for i, lab in enumerate(["Action 1", "Action 2", "Action 3", "Audience", "Sessions", "Uploads"]):
        pg.card(f"ins_{i}", 42, y0 + 120 + i * 52, 1516, 46, f"Insight {lab}", size=10,
                ink=INK if lab.startswith("Action") else INK2, wrap=True)
    pg.footer()
    return pg


def invite() -> Page:
    pg = Page("iv", "Invite", 1302 + 56)
    pg.header("Who to invite", "Which artists should NDN invite to Live at The Cozy Cove next, and why?")
    pg.filters([(col("invite", "ndn_history"), "NDN history", "Dropdown"),
                (col("invite", "on_chart"), "On the Spotify PH chart (8 weeks)", "Dropdown")])
    for i, ((x, w), m) in enumerate(zip(grid(4), ["Artists scored", "Recommended now", "Not now", "Cooling down now"])):
        pg.kpi(f"k{i}", x, 112, w, m)
    parts = [("score", "Score"), ("new_hit_hype", "New-hit hype 25%"), ("momentum", "Momentum 20%"),
             ("local_reach", "Local reach 15%"), ("fan_demand", "Fan demand 10%"), ("track_record", "Track record 10%"),
             ("size", "Size 10%"), ("loyalty", "Loyalty 10%")]
    art = (col("invite", "artist"), "Artist")
    pg.table("top10", 30, 222, 1540, 360,
             [(meas("Inv Rank"), "#"), art, (meas("Inv ndn_history"), "NDN history"),
              *[(meas(f"Inv {c}"), lab) for c, lab in parts]],
             "Top 10 to invite: the score and its parts",
             "Only artists with a NEW HIT that is not on NDN's YouTube yet (a top-5 Spotify song released after their "
             "last NDN visit). Parts are percentiles 0-100, weighted as shown", meas("Inv Rank"), "Ascending",
             bars=[f"Inv {c}" for c, _ in parts])
    pg.table("why", 30, 602, 1540, 360,
             [(meas("Inv Rank"), "#"), art, (meas("Inv new_hit"), "New hit to film"),
              (meas("Inv new_hit_daily_streams"), "Its Spotify streams/day"), (meas("Inv new_hit_released"), "Released"),
              (meas("Inv top_song"), "Top song now"), (meas("Inv top_song_on_ndn"), "Top song on NDN?"),
              (meas("Inv monthly_listeners"), "Monthly listeners"), (meas("Inv best_chart_rank"), "Best PH chart rank"),
              (meas("Inv manila_baguio_listeners"), "Manila + Baguio listeners"),
              (meas("Inv tiktok_followers"), "TikTok followers"), (meas("Inv fans_asking"), "Fans asking NDN"),
              (meas("Inv last_ndn_post"), "Last NDN post")],
             "The numbers behind the top 10: the song to film and the reach behind it",
             "Spotify daily streams via kworb (weekly), Spotify artist page, PH weekly chart, artist TikTok, fan comments",
             meas("Inv Rank"), "Ascending")
    (x1, w1), (x2, w2) = grid(2)
    pg.table("notnow", x1, 982, w1, 320,
             [(meas("Not Rank"), "#"), art, (meas("Not score"), "Score"), (meas("Not hit_status"), "Why not now"),
              (meas("Not top_song"), "Top song now"), (meas("Not top_song_daily_streams"), "Streams/day")],
             "High score, but not now: no new song to film",
             "Their current hit is already on NDN's YouTube, or nothing new since their last visit", meas("Not Rank"),
             "Ascending")
    pg.table("cool", x2, 982, w2, 320,
             [(meas("Cool Rank"), "#"), art, (meas("Cool score"), "Score"), (meas("Cool cooldown_until"), "Invite after"),
              (meas("Cool new_hit"), "New hit"), (meas("Cool fans_asking"), "Fans asking")],
             "Strong artists cooling down",
             "Played for NDN in the last 10 months; invite again after the date shown", meas("Cool Rank"), "Ascending")
    pg.footer()
    return pg


def tiktok() -> Page:
    pg = Page("tt", "TikTok", 2602 + 130 + 56)
    cyan = PLATFORMS["TikTok"]
    pg.header("TikTok", "Which habits make an NDN TikTok travel further than the posts around it?")
    pg.filters([(col("tiktok_video", "published_date_ph"), "Posted", "Between"),
                (col("tiktok_video", "caption_type"), "Caption type", "Dropdown"),
                (col("tiktok_video", "sound_type"), "Sound", "Dropdown")])
    for i, ((x, w), m) in enumerate(zip(grid(4), ["TikTok videos", "Breakouts, all time", "Breakouts, last 30 days",
                                   "Videos made with NDN sounds"])):
        pg.kpi(f"k{i}", x, 112, w, m)
    idx = "Median performance index (views ÷ median of the 30 NDN TikToks posted around it). 1.00 = typical; gold beats it"
    gold = cases("Median Index", [(2, 1, HI), (3, 1, LO)])
    tv = lambda c: col("tiktok_video", c)
    y = 222
    pg.bars("q1", "clusteredColumnChart", 30, y, 1010, 320, tv("published_month"), "Breakout share",
            "Q1 Attract: how often does a video break out, and is it getting more frequent?",
            "Share of the month's TikToks with 2x the views of the posts around them", one_fill(cyan), sort_by_value=False)
    pg.bars("q14", "clusteredColumnChart", 1060, y, 510, 320, tv("published_year"), "Median views per TikTok",
            "Q14: is a 10k-view video today worth a 10k one in 2023?", "Median views per TikTok by year posted",
            one_fill(cyan), sort_by_value=False)
    y += ROW
    for (x, w), (key, vt, c, title) in zip(grid(3), [
            ("q3", "clusteredColumnChart", "length_group", "Q3 Retain: which video length works best?"),
            ("q7", "clusteredBarChart", "sound_type", "Q7 Relevance: original sound or the official track?"),
            ("q6", "clusteredBarChart", "caption_type", "Q6 Relevance: which type of clip beats NDN's average?")]):
        pg.bars(key, vt, x, y, w, 320, tv(c), "Median Index", title, idx, gold, sort_by_value=vt.endswith("BarChart"))
    y += ROW
    g3 = grid(3)
    pg.bars("q4", "clusteredBarChart", g3[0][0], y, g3[0][1], 320, tv("caption_type"), "Median shares+saves per 1k",
            "Q4 Engage: which clips get shared and saved most?", "Median shares + saves per 1,000 views", one_fill(cyan))
    pg.bars("q5", "clusteredColumnChart", g3[1][0], y, g3[1][1], 320, tv("asks_question"), "Median comments per 1k",
            "Q5 Engage: does asking a question start conversations?", "Median comments per 1,000 views; caption asks a question?",
            one_fill(cyan), sort_by_value=False)
    pg.bars("q15", "clusteredColumnChart", g3[2][0], y, g3[2][1], 320, tv("hashtag_group"), "Median Index",
            "Q15: do hashtags help?", idx, gold, sort_by_value=False)
    y += ROW
    for (x, w), (key, c, title) in zip(grid(3), [
            ("q11t", "time_window", "Q11 Habits: what time of day (PH)?"),
            ("q11d", "weekday_ph", "Q11 Habits: which weekday?"),
            ("q11n", "posts_that_day", "Q11 Habits: does posting several a day hurt?")]):
        pg.bars(key, "clusteredColumnChart", x, y, w, 320, tv(c), "Median Index", title, idx, gold, sort_by_value=False)
    y += ROW
    pg.bars("q10", "clusteredColumnChart", g3[0][0], y, g3[0][1], 320, tv("age_band"), "Median 7-day views gained",
            "Q10 Last: how long do videos keep earning views?", "Median views gained in the last 7 days, by video age",
            one_fill(cyan), sort_by_value=False)
    pg.bars("q8", "clusteredBarChart", g3[1][0], y, g3[1][1], 320, tv("caption_type"),
            "Median 7-day gain per 1k, older posts", "Q8: do captions that name the song keep earning longer?",
            "Views gained in the last 7 days per 1,000 views so far, videos older than 30 days", one_fill(cyan))
    pg.bars("q6a", "clusteredBarChart", g3[2][0], y, g3[2][1], 320, tv("artist"), "TikTok Artist Index Top 10",
            "Q6 Relevance: which artists beat NDN's average?", "Top 10 artists with 3+ clips, median index", gold)
    y += ROW
    (x1, w1), (x2, w2) = grid(2)
    pg.table("q4t", x1, y, w1, 320,
             [(tv("caption"), "Caption"), (tv("published_date_ph"), "Posted"), (meas("Shares+saves per 1k"), "Shares+saves per 1k"),
              (meas("TikTok Index 30d"), "Index (last 30 days)")],
             "Q4: the most shared and saved TikToks", "Per 1,000 views; what they have in common is the lesson",
             meas("Shares+saves per 1k"))
    pg.table("q12", x2, y, w2, 320,
             [(tv("caption"), "Caption"), (tv("published_date_ph"), "Posted"), (meas("Sound uses"), "Videos using its sound")],
             "Q12 Music: are other people making videos with NDN sounds?",
             "Videos on each NDN sound page (latest week). Growth needs a few more weeks", meas("Sound uses"))
    y += ROW
    pg.table("q15t", x1, y, w1, 320,
             [(col("tiktok_hashtag", "hashtag"), "Hashtag"), (col("tiktok_hashtag", "videos"), "Videos"),
              (col("tiktok_hashtag", "median_index"), "Median index"), (col("tiktok_hashtag", "breakout_pct"), "Breakout %")],
             "Q15: which hashtags ride with the best posts?", "Hashtags on 10+ videos, all time. Correlation, not cause",
             col("tiktok_hashtag", "median_index"))
    pg.table("top30", x2, y, w2, 320,
             [(tv("caption"), "Caption"), (tv("published_date_ph"), "Posted"),
              (meas("TikTok Views 30d"), "Views"), (meas("TikTok Index 30d"), "Index")],
             "Q1: which TikToks of the last 30 days beat the posts around them?",
             "Sorted by performance index; 2.00 or more = breakout", meas("TikTok Index 30d"))
    y += ROW
    pg.note("na", 30, y, 1540, 130, "Not answerable yet", [
        ("Q2 day-1 takeoff, Q13 TikTok before Spotify:", "need a few weeks of real daily snapshots (started 13 Oct 2026)."),
        ("Q9 followers per video:", "TikTok doesn't publish it; needs NDN's TikTok Studio (Phase 2)."),
        ("Q16 joining trends:", "the PH trend lists started 19 Oct; compare after 4+ weeks.   "
                                "Q17 what to post next week: see the Overview actions.")])
    pg.footer()
    return pg


def youtube() -> Page:
    pg = Page("yt", "YouTube", 2262 + 320 + 56)
    red = PLATFORMS["YouTube"]
    pg.header("YouTube", "Which sessions take off and keep earning, and what does NDN control?")
    pg.filters([(col("dim_video", "published_date_ph"), "Uploaded", "Between"),
                (col("dim_video", "series"), "Series", "Dropdown"),
                (col("dim_video", "video_format"), "Format", "Dropdown")])
    for i, ((x, w), m) in enumerate(zip(grid(4), ["YouTube videos", "Median views/day, full sessions", "Median views/day, Shorts",
                                   "YouTube views gained, last 7 days"])):
        pg.kpi(f"k{i}", x, 112, w, m)
    vpd = "Median views per day (latest views ÷ days since upload)"
    dv = lambda c: col("dim_video", c)
    y = 222
    pg.table("q1", 30, y, 1010, 320,
             [(dv("title"), "Video"), (dv("published_date_ph"), "Uploaded"),
              (meas("YouTube Views/Day 90d"), "Views per day"), (meas("YouTube vs Series 90d"), "vs series median")],
             "Q1 Attract: which new sessions are taking off?",
             "Uploads of the last 90 days. vs series median: 2.0 = twice a typical video of the same series",
             meas("YouTube Views/Day 90d"))
    pg.scatter("q1s", 1060, y, 510, 320, dv("title"), "YouTube artist listeners", "YouTube views per day",
               "Q1: allowing for how big the artist is", "Full sessions: views/day vs the artist's Spotify monthly "
               "listeners. Dots high on the left beat their size", red)
    y += ROW
    g3 = grid(3)
    pg.bars("q6", "clusteredBarChart", g3[0][0], y, g3[0][1], 320, dv("series"), "YouTube Median Views/Day",
            "Q6 Relevance: which series work?", vpd, one_fill(red))
    pg.bars("q10d", "clusteredColumnChart", g3[1][0], y, g3[1][1], 320, dv("published_weekday_ph"),
            "Median views/day, full sessions", "Q10 Habits: does the Mon/Wed/Fri slot matter?", vpd + ", full sessions",
            one_fill(red), sort_by_value=False)
    pg.bars("q10h", "clusteredColumnChart", g3[2][0], y, g3[2][1], 320, dv("upload_slot"),
            "Median views/day, full sessions", "Q10 Habits: does the 7 pm upload matter?", vpd + ", full sessions",
            one_fill(red), sort_by_value=False)
    y += ROW
    pg.bars("q3", "clusteredColumnChart", g3[0][0], y, g3[0][1], 320, col("yt_heatmap", "peak_band"), "Sessions",
            "Q3 Retain: which moment do viewers replay most?",
            "Sessions by where their 'most replayed' peak sits (% into the video)", one_fill(red), sort_by_value=False)
    pg.bars("q4", "clusteredBarChart", g3[1][0], y, g3[1][1], 320, dv("series"), "YouTube engagement rate",
            "Q4 Engage: what makes viewers like and comment?", "Median (likes + comments) ÷ views, by series", one_fill(red))
    pg.scatter("q5", g3[2][0], y, g3[2][1], 320, dv("title"), "YouTube song Spotify streams", "YouTube views per day",
               "Q5 Relevance: does the song choice decide the views?",
               "Session views/day vs the studio song's Spotify streams", red)
    y += ROW
    pg.bars("q8", "clusteredColumnChart", 30, y, 500, 320, dv("age_band"), "YouTube median 7-day gain",
            "Q8 Last: how long do sessions keep earning?", "Median views gained in the last 7 days, by video age",
            one_fill(red), sort_by_value=False)
    pg.table("q8t", 550, y, 1020, 320,
             [(dv("title"), "Video"), (dv("published_date_ph"), "Uploaded"),
              (meas("YouTube 7-day gain, older sessions"), "Views gained, last 7 days")],
             "Q8: which old sessions keep earning or come back?", "Sessions over a year old, by views gained in the last 7 days",
             meas("YouTube 7-day gain, older sessions"))
    y += ROW
    pg.bars("q7", "clusteredColumnChart", 30, y, 500, 320, col("yt_search", "rank_band"), "Searches",
            "Q7 Search: when people search a filmed song, where does NDN rank?",
            "90 YouTube searches (song + artist), latest Monday", one_fill(red), sort_by_value=False)
    pg.table("q7t", 550, y, 1020, 320,
             [(col("yt_search", "query"), "Search"), (col("yt_search", "ndn_best_rank"), "NDN rank"),
              (col("yt_search", "first_channel"), "Ranked first"), (col("yt_search", "reason"), "Why searched")],
             "Q7: who beats NDN on its own songs?", "Lowest NDN rank first", col("yt_search", "ndn_best_rank"))
    y += ROW
    (x1, w1), (x2, w2) = grid(2)
    pg.table("q11", x1, y, w1, 320,
             [(col("yt_trending", "rank"), "#"), (col("yt_trending", "title"), "Trending video"),
              (col("yt_trending", "channel_title"), "Channel"), (col("yt_trending", "views"), "Views"),
              (col("yt_trending", "is_ndn"), "NDN?")],
             "Q11 Trends: what trends in PH music on YouTube today?", "YouTube's PH Trending Music list, latest day",
             col("yt_trending", "rank"), "Ascending")
    pg.line("last", x2, y, w2, 320, col("platform_daily", "snapshot_date"), "YouTube Views Gained Real",
            "Last: how many views does the whole channel gain each day?",
            "Sum over all videos, real snapshots only (filters don't apply)", red)
    y += ROW
    pg.bars("artists", "clusteredBarChart", g3[0][0], y, g3[0][1], 320, dv("artist"),
            "YouTube Artist Views/Day Top 10", "Q5: which artists bring the most daily views?",
            "Top 10, views per day summed over each artist's videos", one_fill(red))
    pg.bars("q2", "clusteredColumnChart", g3[1][0], y, g3[1][1], 320, dv("video_format"), "YouTube Median Views/Day",
            "Q2: full sessions vs Shorts", vpd, one_fill(red))
    pg.note("na", g3[2][0], y, g3[2][1], 320, "Not answerable yet", [
        ("Q2 Shorts → full sessions:", "traffic sources are private (YouTube Studio, Phase 2)."),
        ("Q9 does a new session wake old ones:", "needs 4+ weeks of daily history."),
        ("Q12 Spotify lift (flagship):", "kworb weekly streams before vs after a session; first read after 4-8 weeks."),
        ("Q13 invite score:", "track record on the Who to invite page."),
        ("Q14 next week:", "see the Overview actions.")])
    pg.footer()
    return pg


def instagram() -> Page:
    pg = Page("ig", "Instagram", 1582 + 320 + 56)
    pink = PLATFORMS["Instagram"]
    pg.header("Instagram", "Which Reels reach beyond NDN's followers, and what makes people pass them on?")
    pg.filters([(col("dim_video", "published_date_ph"), "Posted", "Between"),
                (col("dim_video", "video_format"), "Format", "Dropdown")])
    for i, ((x, w), m) in enumerate(zip(grid(4), ["Instagram posts", "Median likes/day, all posts", "Median views/day, Reels",
                                   "Instagram likes gained, last 6 days"])):
        pg.kpi(f"k{i}", x, 112, w, m)
    lpd = "Median likes per day (latest likes ÷ days since posting)"
    dv = lambda c: col("dim_video", c)
    (x1, w1), (x2, w2) = grid(2)
    y = 222
    pg.scatter("q1", x1, y, w1, 320, dv("title"), "Reel artist listeners", "Reel views per day",
               "Q1 Attract: which Reels break out, allowing for the artist's size?",
               "Reel views/day vs the artist's Spotify monthly listeners. Dots high on the left beat their size", pink)
    pg.table("q1t", x2, y, w2, 320,
             [(dv("title"), "Post"), (dv("published_date_ph"), "Posted"), (dv("video_format"), "Format"),
              (meas("Instagram Likes/Day 90d"), "Likes per day"), (meas("Instagram Views/Day 90d"), "Views per day")],
             "Q1: which posts of the last 90 days are taking off?",
             "Views only for Reels (public view counts include Facebook views since Apr 2026)", meas("Instagram Likes/Day 90d"))
    y += ROW
    g3 = grid(3)
    pg.bars("q2", "clusteredBarChart", g3[0][0], y, g3[0][1], 320, dv("video_format"), "Median likes/day, all posts",
            "Q2: what does each format do?", lpd, one_fill(pink))
    pg.bars("q7", "clusteredBarChart", g3[1][0], y, g3[1][1], 320, dv("series"), "Median likes/day, all posts",
            "Q7 Relevance: which series work on Instagram?", lpd, one_fill(pink))
    pg.bars("q11", "clusteredBarChart", g3[2][0], y, g3[2][1], 320, dv("ig_caption_type"), "Median likes/day, all posts",
            "Q11 Habits: teaser before the Premiere or 'now streaming' after?", lpd, one_fill(pink))
    y += ROW
    pg.bars("q4", "clusteredBarChart", g3[0][0], y, g3[0][1], 320, dv("ig_caption_type"), "Median reposts per 1k views",
            "Q4 Engage: which Reels get passed on?", "Median reposts per 1,000 views (shares and saves are private)",
            one_fill(pink))
    pg.bars("q5", "clusteredBarChart", g3[1][0], y, g3[1][1], 320, dv("ig_caption_type"), "Median comments per 1k likes",
            "Q5 Engage: which posts start conversations?", "Median comments per 1,000 likes", one_fill(pink))
    pg.bars("q8", "clusteredColumnChart", g3[2][0], y, g3[2][1], 320, dv("ig_hashtag_group"), "Median likes/day, all posts",
            "Q8 Search: do hashtags help?", lpd, one_fill(pink), sort_by_value=False)
    y += ROW
    pg.bars("q10", "clusteredColumnChart", g3[0][0], y, g3[0][1], 320, dv("age_band"), "Instagram median 7-day likes gained",
            "Q10 Last: how fast do posts fade?", "Median likes gained in the last 7 days, by post age",
            one_fill(pink), sort_by_value=False)
    pg.bars("q11d", "clusteredColumnChart", g3[1][0], y, g3[1][1], 320, dv("published_weekday_ph"),
            "Median likes/day, all posts", "Q11 Habits: does the weekday matter?", lpd, one_fill(pink), sort_by_value=False)
    pg.line("last", g3[2][0], y, g3[2][1], 320, col("platform_daily", "snapshot_date"), "Instagram Likes Gained Real",
            "Last: likes gained each day", "All posts, real snapshots from 15 Oct 2026 (filters don't apply)", pink)
    y += ROW
    pg.scatter("q6", 30, y, 1010, 320, col("song_compare", "song"), "Song YouTube views", "Song Instagram likes",
               "Q6 Relevance: does Instagram reward the same songs as YouTube?",
               "One dot per song filmed by NDN: YouTube views vs Instagram likes (filters don't apply)", pink)
    pg.note("na", 1060, y, 510, 320, "Not answerable yet", [
        ("Q3 opening moment and length:", "Instagram doesn't publish Reel length or watch time (Phase 2)."),
        ("Q9 Reels that bring followers:", "private (Instagram Insights, Phase 2)."),
        ("Q12 Spotify lift:", "kworb weekly streams around a push; first read after 4-8 weeks."),
        ("Q13 invite score:", "see the Who to invite page."),
        ("Q14 next week:", "see the Overview actions.")])
    pg.footer()
    return pg


def benchmarks() -> Page:
    pg = Page("bm", "Benchmarks", 1010)
    pg.header("Benchmarks", "How does NDN compare with other live-session channels at home, in Asia and abroad?")
    pg.filters([(col("dim_account", "region"), "Region", "Dropdown"),
                (col("dim_account", "account"), "Account", "Dropdown")])
    rows = [("fol", "bench_accounts", "Followers {p}", "Is NDN Account", "{p}: followers",
             "Latest snapshot. Gold = Nine Degrees North"),
            ("med", "bench_uploads", "Median Views {p}", "Is NDN Uploads", "{p}: median views per upload",
             "Uploads of the last 12 months (older than 14 days), views today"),
            ("upl", "bench_uploads", "Uploads/Month {p}", "Is NDN Uploads", "{p}: uploads per month",
             "Average over the last 12 months")]
    for r, (key, tbl, mfmt, flag, tfmt, sub) in enumerate(rows):
        for i, p in enumerate(PLATFORMS):
            pg.bars(f"{key}_{p}", "clusteredBarChart", 30 + i * 520, 112 + r * 280, 500, 262, col(tbl, "account"),
                    mfmt.format(p=p), tfmt.format(p=p), sub, cases(flag, [(0, 1, HI), (0, 0, LO)]))
    pg.footer("Domestic: Wish 107.5 (Wish Bus), Backyard Live · Asia: THE FIRST TAKE (Japan), it's Live (Korea) · "
              "International: NPR Music (Tiny Desk). Growth over time starts with the daily snapshots from 21 Oct 2026.")
    return pg


def community() -> Page:
    pg = Page("cm", "Community", 980)
    pg.header("Community", "Who do fans ask NDN to invite next, and which sessions do they want uploaded?")
    pg.filters([(col("fan_demand", "status"), "Artist status", "Dropdown"),
                (col("fan_demand", "latest_ask"), "Latest ask", "Between")])
    for i, m in enumerate(["Artists fans ask for", "Never on NDN", "Artists with upload requests"]):
        pg.kpi(f"k{i}", 30 + i * 523, 112, 494, m)
    pg.bars("top", "clusteredBarChart", 30, 222, 620, 420, col("fan_demand", "artist"), "Fans Asking Top 15",
            "Which artists do fans ask NDN for most?",
            "Distinct fans in YouTube + TikTok comments, last 12 months. Gold = never on NDN",
            cases("Is Never Played", [(0, 1, HI), (0, 0, LO)]))
    pg.table("demand", 670, 222, 900, 420,
             [(col("fan_demand", "artist"), "Artist"), (col("fan_demand", "status"), "Status"),
              (meas("Fans Asking"), "Fans"), (col("fan_demand", "youtube_asks"), "YouTube asks"),
              (col("fan_demand", "tiktok_asks"), "TikTok asks"), (col("fan_demand", "latest_ask"), "Latest ask"),
              (col("fan_demand", "cooling_down"), "Cooling down")],
             "Every artist fans asked for",
             "Cooling down = played for NDN in the last 10 months (not recommended again yet)", meas("Fans Asking"))
    pg.table("uploads", 30, 662, 1540, 280,
             [(col("fan_upload", "artist"), "Artist"), (col("fan_upload", "fans"), "Fans"),
              (col("fan_upload", "asks"), "Asks"), (col("fan_upload", "asks_for_streaming"), "Want it on streaming"),
              (col("fan_upload", "top_ask"), "Example comment")],
             "Which sessions do fans want uploaded or on Spotify?",
             "Comments asking NDN to post a filmed session, or to release it on streaming (filters don't apply)",
             col("fan_upload", "fans"))
    pg.footer()
    return pg


# --------------------------------------------------------------------------------------------- report
def dark_theme() -> dict:
    t = json.loads((THEMES / "light_template.json").read_text(encoding="utf-8"))
    swap = {"#0B0B0B": INK, "#FCFCFB": CARD, "#898781": INK3, "#F9F9F7": PAGE, "#52514E": INK2, "#DCDAD2": LINE,
            "#E6E5DF": LINE, "#E1E0D9": GRID, "#F4F4F1": "#202020"}
    text = json.dumps(t)
    for old, new in swap.items():
        text = text.replace(f'"{old}"', f'"{new}"').replace(f'"{old.lower()}"', f'"{new}"')
    t = json.loads(text)
    t["name"] = "NDN dark"
    t["dataColors"] = [*PLATFORMS.values(), HI, LO, "#3987e5", "#d95926", "#199e70"]
    t["background"], t["secondaryBackground"], t["foreground"] = PAGE, CARD, INK
    t["tableAccent"] = PLATFORMS["TikTok"]
    vals = t["visualStyles"]["tableEx"]["*"]["values"][0]
    vals["fontColorSecondary"] = {"solid": {"color": INK}}
    t["visualStyles"]["page"]["*"]["pageSize"] = [{"pageSizeTypes": "Custom", "pageSizeWidth": 1600, "pageSizeHeight": 900}]
    return t


def clear(folder: Path) -> None:
    """Delete every file under folder, then the empty folders. A folder that Power BI Desktop is watching can't be
    removed on Windows, so it stays (empty) instead of stopping the build."""
    if not folder.exists():
        return
    for f in folder.rglob("*"):
        if f.is_file():
            f.unlink()
    for d in sorted((d for d in folder.rglob("*") if d.is_dir()), key=lambda d: len(d.parts), reverse=True):
        try:
            d.rmdir()
        except OSError:
            pass


def build_report(pages: list[Page]) -> None:
    for sub in ("definition", "StaticResources"):
        clear(REPORT / sub)
    write_json(REPORT / ".platform", {
        "$schema": f"{SCHEMA}/gitIntegration/platformProperties/2.0.0/schema.json",
        "metadata": {"type": "Report", "displayName": NAME},
        "config": {"version": "2.0", "logicalId": tag("report")}})
    write_json(REPORT / "definition.pbir", {
        "$schema": f"{SCHEMA}/item/report/definitionProperties/2.0.0/schema.json", "version": "4.0",
        "datasetReference": {"byPath": {"path": f"../{NAME}.SemanticModel"}}})
    d = REPORT / "definition"
    write_json(d / "version.json", {"$schema": f"{SCHEMA}/item/report/definition/versionMetadata/1.0.0/schema.json",
                                    "version": "2.0.0"})
    base_name = "Fluent2-CY26SU08"
    write_json(d / "report.json", {
        "$schema": f"{SCHEMA}/item/report/definition/report/3.3.0/schema.json",
        "themeCollection": {
            "baseTheme": {"name": base_name, "reportVersionAtImport": THEME_VERSIONS, "type": "SharedResources"},
            "customTheme": {"name": "NDN_dark.json", "reportVersionAtImport": THEME_VERSIONS, "type": "RegisteredResources"}},
        "objects": {"section": props(verticalAlignment=s("Top")), "outspacePane": props(expanded=b(False))},
        "resourcePackages": [
            {"name": "SharedResources", "type": "SharedResources",
             "items": [{"name": base_name, "path": f"BaseThemes/{base_name}.json", "type": "BaseTheme"}]},
            {"name": "RegisteredResources", "type": "RegisteredResources",
             "items": [{"name": "NDN_dark.json", "path": "NDN_dark.json", "type": "CustomTheme"}]}],
        "settings": {"useStylableVisualContainerHeader": True, "exportDataMode": "AllowSummarized",
                     "defaultDrillFilterOtherVisuals": True, "allowChangeFilterTypes": True,
                     "useEnhancedTooltips": True, "useDefaultAggregateDisplayName": True}})
    shutil.copy(THEMES / f"{base_name}.json", _mk(REPORT / "StaticResources/SharedResources/BaseThemes") / f"{base_name}.json")
    write_json(REPORT / "StaticResources/RegisteredResources/NDN_dark.json", dark_theme())
    write_json(d / "pages/pages.json", {"$schema": f"{SCHEMA}/item/report/definition/pagesMetadata/1.1.0/schema.json",
                                        "pageOrder": [p.pid for p in pages], "activePageName": pages[0].pid})
    for p in pages:
        write_json(d / "pages" / p.pid / "page.json", {
            "$schema": f"{SCHEMA}/item/report/definition/page/2.1.0/schema.json",
            "name": p.pid, "displayName": p.display, "displayOption": p.option, "height": p.height, "width": 1600,
            "objects": {"background": props(color=color(PAGE), transparency=n(0)),
                        "outspace": props(color=color(PAGE), transparency=n(0))}})
        for v in p.visuals:
            write_json(d / "pages" / p.pid / "visuals" / v["name"] / "visual.json", v)


def _mk(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    return path


def check(pages: list[Page]) -> None:
    """The two mistakes that cost the most last time: duplicate visual names and measures that don't exist."""
    names = [v["name"] for p in pages for v in p.visuals]
    dupes = {x for x in names if names.count(x) > 1}
    assert not dupes, f"duplicate visual names: {dupes}"
    known = {m[1] for m in MEASURES}
    used = set()
    for p in pages:
        for v in p.visuals:
            text = json.dumps(v)
            for part in text.split('"Entity": "_Measures"}}, "Property": "')[1:]:
                used.add(part.split('"')[0])
    missing = used - known
    assert not missing, f"visuals use unknown measures: {missing}"


def main() -> None:
    schema = json.loads((DATA / "_schema.json").read_text(encoding="utf-8"))
    build_model(schema)
    pages = [overview(), invite(), tiktok(), youtube(), instagram(), benchmarks(), community()]
    check(pages)
    build_report(pages)
    write_json(PBI / f"{NAME}.pbip", {
        "$schema": f"{SCHEMA}/pbip/pbipProperties/1.0.0/schema.json", "version": "1.0",
        "artifacts": [{"report": {"path": f"{NAME}.Report"}}], "settings": {"enableAutoRecovery": True}})
    print(f"{len(MEASURES)} measures, {sum(len(p.visuals) for p in pages)} visuals on {len(pages)} pages -> {PBI / NAME}.pbip")


if __name__ == "__main__":
    main()
