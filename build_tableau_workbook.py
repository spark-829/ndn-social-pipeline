"""Write tableau/NDN_dashboard.twbx: the Tableau Public workbook (dashboard v2, 2026-10-19).

A .twbx is a zip of the workbook XML (.twb) plus its data as Tableau extracts (.hyper, built here from the CSV
files of export_tableau.py with the free tableauhyperapi package). So the workbook is rebuilt from code instead of
by hand. Open it in Tableau Public, check each dashboard, then swap the sources to the Google Sheet and publish.

Dashboards (plan and reasons: TABLEAU_DATA.md):
    0 Executive   overall state per platform + the actions to take (daily Claude text)
    1 TikTok      one chart per TikTok question (TIKTOK_QUESTIONS.md), goal: more views. Long scrolling page.
    2 YouTube     simple version (own question list comes later)
    3 Instagram   simple version (own question list comes later)

Usage:  py build_tableau_workbook.py            (needs: py -m pip install tableauhyperapi)
"""
import re
import zipfile
from datetime import datetime
from pathlib import Path
from xml.sax.saxutils import escape

from tableauhyperapi import (Connection, CreateMode, HyperProcess, SqlType, TableDefinition, TableName,
                             Telemetry, escape_string_literal)

BASE = Path(__file__).resolve().parent
DATA_DIR = (BASE / "tableau").as_posix()
OUT = BASE / "tableau" / "NDN_dashboard.twbx"
UPDATE_TIME = datetime.now().strftime("%m/%d/%Y %I:%M:%S %p")
NOTE = ("Independent analysis of public data, not affiliated with Nine Degrees North. "
        "All numbers are real public counts (daily snapshots since 12-15 Oct 2026). Built by Vicson Yaris.")


def q(s) -> str:
    """Escape a value for an XML attribute in single quotes."""
    return escape(str(s), {"'": "&apos;", '"': "&quot;"})


# ---------- data sources: name -> (csv, [(column, datatype, role, type)], {calc_id: (caption, datatype, role, type, formula)})
S, I, R, D, B = "string", "integer", "real", "date", "boolean"
DIM_N, DIM_O, MEA = ("dimension", "nominal"), ("dimension", "ordinal"), ("measure", "quantitative")
AGG_S = ("measure", "nominal")          # aggregate calc that returns text (BAN labels, colour flags)


def short(x: str) -> str:
    """Tableau formula: a number as 1.5M / 325.7K / 950."""
    return (f'(IF {x} >= 1000000 THEN STR(ROUND({x} / 1000000, 2)) + "M" '
            f'ELSEIF {x} >= 1000 THEN STR(ROUND({x} / 1000, 1)) + "K" ELSE STR({x}) END)')


SOURCES = {
    "account": ("fact_account_daily.csv", [
        ("platform", S, *DIM_N), ("snapshot_date", D, *DIM_O), ("data_source", S, *DIM_N), ("followers", I, *MEA),
        ("followers_gained", I, *MEA), ("total_views", I, *MEA), ("views_gained", I, *MEA),
        ("video_count", I, *MEA), ("hearts", I, *MEA)], {}),
    "video": ("dim_video.csv", [
        ("platform", S, *DIM_N), ("video_id", S, *DIM_N), ("title", S, *DIM_N), ("url", S, *DIM_N),
        ("published_at", S, *DIM_N), ("published_date_ph", D, *DIM_O), ("published_weekday_ph", S, *DIM_N),
        ("published_weekday_num", I, *DIM_O), ("published_hour_ph", I, *DIM_O), ("duration_sec", I, *MEA),
        ("format", S, *DIM_N), ("series", S, *DIM_N), ("session", S, *DIM_N), ("song", S, *DIM_N),
        ("artist", S, *DIM_N), ("song_key", S, *DIM_N), ("mentions_cozy_cove", S, *DIM_N),
        ("latest_views", I, *MEA), ("latest_likes", I, *MEA), ("latest_comments", I, *MEA),
        ("latest_snapshot", D, *DIM_O), ("age_days", I, *MEA), ("views_per_day", R, *MEA),
        ("likes_per_day", R, *MEA), ("perf_per_day", R, *MEA), ("engagement_rate", R, *MEA),
        ("vs_series_median", R, *MEA)],
        {"Calculation_201": ("Post", S, *DIM_N, "LEFT([title], 70)"),
         "Calculation_303": ("Series group", S, *DIM_N,
                             'IF [series]="Live at The Cozy Cove" THEN "Live at The Cozy Cove" ELSE "Other series" END')}),
    "songs": ("song_compare.csv", [
        ("song_key", S, *DIM_N), ("song", S, *DIM_N), ("artist", S, *DIM_N), ("youtube_views", I, *MEA),
        ("tiktok_views", I, *MEA), ("instagram_likes", I, *MEA), ("youtube_videos", I, *MEA),
        ("tiktok_videos", I, *MEA), ("instagram_posts", I, *MEA), ("is_cozy_cove", S, *DIM_N)], {}),
    # sentences written daily by the Claude routine "NDN dashboard insights" from mart.insight_facts
    "insights": ("insights.csv", [
        ("as_of", D, *DIM_O), ("slot", S, *DIM_N), ("sort_order", I, *DIM_O), ("text", S, *DIM_N),
        ("written_by", S, *DIM_N)],
        {"Calculation_501": ("Action number", S, *DIM_N, "STR([sort_order] - 1)")}),
    # v2 (sql/012_dashboard_v2.sql): one row per TikTok video with everything the TikTok questions need
    "tiktok": ("tiktok_video.csv", [
        ("video_id", S, *DIM_N), ("url", S, *DIM_N), ("caption", S, *DIM_N), ("published_at", S, *DIM_N),
        ("published_date_ph", D, *DIM_O), ("weekday_ph", S, *DIM_N), ("weekday_num", I, *DIM_O),
        ("hour_ph", I, *DIM_O), ("time_window", S, *DIM_N), ("posts_that_day", I, *MEA), ("duration_sec", I, *MEA),
        ("length_group", S, *DIM_N), ("views", I, *MEA), ("likes", I, *MEA), ("comments", I, *MEA),
        ("shares", I, *MEA), ("saves", I, *MEA), ("latest_snapshot", D, *DIM_O), ("age_days", I, *MEA),
        ("is_mature", S, *DIM_N), ("is_last_30d", S, *DIM_N), ("likes_per_1k", R, *MEA),
        ("comments_per_1k", R, *MEA), ("shares_per_1k", R, *MEA), ("saves_per_1k", R, *MEA),
        ("share_save_per_1k", R, *MEA), ("share_save_group", S, *DIM_N), ("neighbour_median", R, *MEA),
        ("perf_index", R, *MEA), ("index_band", S, *DIM_N), ("views_gained_7d", I, *MEA),
        ("gained_since", D, *DIM_O), ("caption_type", S, *DIM_N), ("asks_question", S, *DIM_N),
        ("n_hashtags", I, *MEA), ("hashtag_group", S, *DIM_N), ("track", S, *DIM_N), ("sound_type", S, *DIM_N),
        ("song", S, *DIM_N), ("artist", S, *DIM_N), ("series", S, *DIM_N)],
        {"Calculation_601": ("Vs typical", S, *AGG_S,
                             'IF MEDIAN([perf_index]) >= 1 THEN "Beats typical (1+)" ELSE "Below typical" END'),
         "Calculation_602": ("Breakout %", R, *MEA, "AVG(IIF([perf_index] >= 2, 100, 0))"),
         "Calculation_603": ("Last 6 months", B, *DIM_N, "DATEDIFF('day', [published_date_ph], [latest_snapshot]) <= 182"),
         "Calculation_604": ("Posts that day", S, *DIM_N,
                             'IF [posts_that_day] >= 3 THEN "3+ posts" ELSEIF [posts_that_day] = 2 THEN "2 posts" '
                             'ELSE "1 post" END'),
         "Calculation_605": ("Post", S, *DIM_N, "LEFT([caption], 70)"),
         "Calculation_606": ("Last 24 months", B, *DIM_N, "DATEDIFF('month', [published_date_ph], [latest_snapshot]) < 24"),
         "Calculation_607": ("Breakout rate 30d", S, *AGG_S,
                             'STR(ROUND(AVG(IF [is_last_30d] = "yes" THEN IIF([perf_index] >= 2, 100, 0) END), 0)) + "%"'),
         "Calculation_608": ("Breakout rate sub", S, *AGG_S,
                             '"of posts in the last 30 days reached 2x typical views (all-time " '
                             '+ STR(ROUND(AVG(IIF([perf_index] >= 2, 100, 0)), 0)) + "%)"'),
         "Calculation_609": ("Share save 30d", S, *AGG_S,
                             'STR(ROUND(MEDIAN(IF [is_last_30d] = "yes" THEN [share_save_per_1k] END), 1))'),
         "Calculation_610": ("Share save sub", S, *AGG_S,
                             '"shares + saves per 1,000 views, median of the last 30 days (all-time " '
                             '+ STR(ROUND(MEDIAN([share_save_per_1k]), 1)) + ")"'),
         "Calculation_611": ("Older than 30 days", B, *DIM_N, "[age_days] > 30"),
         "Calculation_612": ("10k+ views", B, *DIM_N, "[views] >= 10000")}),
    "hashtags": ("tiktok_hashtag.csv", [
        ("hashtag", S, *DIM_N), ("videos", I, *MEA), ("median_index", R, *MEA), ("breakout_pct", R, *MEA),
        ("median_views", R, *MEA)],
        {"Calculation_801": ("Vs typical", S, *AGG_S,
                             'IF SUM([median_index]) >= 1 THEN "Beats typical (1+)" ELSE "Below typical" END')}),
    "scorecard": ("platform_scorecard.csv", [
        ("platform", S, *DIM_N), ("as_of", D, *DIM_O), ("window_start", D, *DIM_O), ("window_days", I, *MEA),
        ("metric_name", S, *DIM_N), ("followers", I, *MEA), ("followers_change", I, *MEA),
        ("followers_change_pct", R, *MEA), ("metric_gained", I, *MEA), ("posts_in_window", I, *MEA),
        ("best_post", S, *DIM_N), ("best_post_url", S, *DIM_N), ("best_post_gained", I, *MEA)],
        {"Calculation_701": ("Followers", S, *DIM_N, short("[followers]")),
         # YouTube's API rounds subscribers to 3 digits (1.51M = 1,510,000-1,519,999), so a week can show +0
         "Calculation_702": ("New followers this week", S, *DIM_N,
                             'IF [platform] = "YouTube" THEN "hidden (YouTube rounds)" ELSE '
                             '"+" + ' + short("[followers_change]") + ' + " (+" '
                             '+ STR(ROUND([followers_change_pct], 1)) + "%)" END'),
         "Calculation_703": ("Gained this week", S, *DIM_N, short("[metric_gained]") + ' + " " + [metric_name]'),
         "Calculation_704": ("Best post gain", S, *DIM_N, '"+" + ' + short("[best_post_gained]") + ' + " " + [metric_name]'),
         "Calculation_705": ("Best post this week", S, *DIM_N, "LEFT([best_post], 90)"),
         "Calculation_706": ("New posts", S, *DIM_N, "STR([posts_in_window])"),
         "Calculation_707": ("Days tracked", S, *DIM_N, "STR([window_days]) + \" days\""),
         # executive big numbers
         "Calculation_711": ("BAN followers", S, *AGG_S, short("SUM([followers])")),
         "Calculation_712": ("BAN new followers", S, *AGG_S,
                             '"+" + ' + short('SUM(IF [platform] <> "YouTube" THEN [followers_change] END)')),
         "Calculation_713": ("BAN views", S, *AGG_S,
                             short('SUM(IF [metric_name] = "views" THEN [metric_gained] END)')),
         "Calculation_714": ("BAN posts", S, *AGG_S, "STR(SUM([posts_in_window]))")}),
}

# Colours: dataviz reference palette (validated). Categorical slots in fixed order, entity keeps its colour.
# Dark theme in NDN's black and white: white = highlight, gray = context, platform hues only for platform identity.
BLUE, ORANGE, AQUA = "#3987e5", "#d95926", "#199e70"     # dark-mode slots 1-3 (validated all-pairs on #1a1a19)
HILITE = "#f0efec"                                        # emphasis: the thing the eye should land on
MUTED = "#5c5b57"                                         # de-emphasis gray, recedes on the dark card
MID = "#a3a29a"                                           # middle step of the gray ramp (ordered bands)
INK, INK2, INK3 = "#f0efec", "#c3c2b7", "#898781"         # primary / secondary / muted text
GRID = "#2c2c2a"
PAGE_BG, CARD_BG = "#0d0d0d", "#1a1a19"                   # page plane and cards (dark surfaces from the palette)
THEME = (f"<style-rule element='worksheet'><format attr='font-family' value='Segoe UI' />"
         f"<format attr='color' value='{INK2}' /><format attr='background-color' value='{CARD_BG}' /></style-rule>"
         f"<style-rule element='table'><format attr='background-color' value='{CARD_BG}' /></style-rule>"
         f"<style-rule element='gridline'><format attr='stroke-color' value='{GRID}' /></style-rule>"
         f"<style-rule element='zeroline'><format attr='stroke-color' value='{GRID}' /></style-rule>")
PLATFORM_COLORS = {"YouTube": BLUE, "TikTok": ORANGE, "Instagram": AQUA}
VS_TYPICAL = {"Beats typical (1+)": HILITE, "Below typical": MUTED}
BANDS = {"1 Breakout (2x+)": HILITE, "2 Above typical (1-2x)": MID, "3 Below typical": MUTED}
CAPTIONS = {"account": "Accounts (followers)", "video": "Videos", "songs": "Songs across platforms",
            "insights": "Insights (daily text)", "tiktok": "TikTok videos", "hashtags": "TikTok hashtags",
            "scorecard": "Platform scorecard"}


TWO_DECIMALS = {"perf_index", "median_index", "neighbour_median"}


def ds_name(src: str) -> str:
    return f"federated.ndn{src}"


def col_meta(src: str, col: str):
    _, cols, calcs = SOURCES[src]
    for name, dt, role, typ in cols:
        if name == col:
            return dt, role, typ, None, None
    caption, dt, role, typ, formula = calcs[col]
    return dt, role, typ, caption, formula


def column_xml(src: str, col: str, indent: str) -> str:
    dt, role, typ, caption, formula = col_meta(src, col)
    # same caption the Google Drive connector gives ("youtube_views" -> "Youtube Views"), so swapping the CSV
    # sources for the Google Sheet keeps every field linked
    caption = caption or " ".join(w.capitalize() for w in col.split("_"))
    cap = f" caption='{q(caption)}'"
    # number format (axes, tooltips): whole numbers with commas; indexes 2 decimals; other decimals 1
    fmt = {"integer": "n#,##0", "real": "n#,##0.0"}.get(dt)
    if col in TWO_DECIMALS:
        fmt = "n#,##0.00"
    if fmt and role == "measure":
        cap += f" default-format='{fmt}'"
    if formula is None:
        return f"{indent}<column{cap} datatype='{dt}' name='[{col}]' role='{role}' type='{typ}' />\n"
    return (f"{indent}<column{cap} datatype='{dt}' name='[{col}]' role='{role}' type='{typ}'>\n"
            f"{indent}  <calculation class='tableau' formula='{q(formula)}' />\n{indent}</column>\n")


def datasource_xml(src: str) -> str:
    csv, cols, calcs = SOURCES[src]
    conn = f"textscan.ndn{src}"
    rel_cols = "".join(f"            <column datatype='{dt}' name='{n}' ordinal='{i}' />\n"
                       for i, (n, dt, _, _) in enumerate(cols))
    meta_cols = "".join(column_xml(src, n, "      ") for n, *_ in cols)
    calc_cols = "".join(column_xml(src, c, "      ") for c in calcs)
    # Tableau Public only opens/saves workbooks whose data are extracts (.hyper files packed into the .twbx)
    extract = f"""      <extract count='-1' enabled='true' units='records'>
        <connection access_mode='readonly' authentication='auth-none' author-locale='en_US' class='hyper' dbname='Data/Extracts/{src}.hyper' default-settings='hyper' schema='Extract' sslmode='' tablename='Extract' update-time='{UPDATE_TIME}' username='tableau_internal_user'>
          <relation name='Extract' table='[Extract].[Extract]' type='table' />
        </connection>
      </extract>
"""
    return f"""    <datasource caption='{q(CAPTIONS[src])}' inline='true' name='{ds_name(src)}' version='18.1'>
      <connection class='federated'>
        <named-connections>
          <named-connection caption='tableau' name='{conn}'>
            <connection class='textscan' directory='{q(DATA_DIR)}' filename='{csv}' password='' server='' />
          </named-connection>
        </named-connections>
        <relation connection='{conn}' name='{csv}' table='[{csv.replace(".", "#")}]' type='table'>
          <columns character-set='UTF-8' header='yes' locale='en_US' separator=','>
{rel_cols}          </columns>
        </relation>
      </connection>
      <aliases enabled='yes' />
{meta_cols}{calc_cols}{extract}    </datasource>
"""


# ---------- worksheets
DERIV = {"none": "None", "sum": "Sum", "avg": "Avg", "med": "Median", "tdy": "Day-Trunc", "tmn": "Month-Trunc",
         "usr": "User"}
NL = "Æ&#10;"                      # how Tableau writes a line break inside formatted text


def run(text: str, size: int = 10, color: str = INK2, bold: bool = False) -> str:
    b = " bold='true'" if bold else ""
    return f"<run{b} fontcolor='{color}' fontsize='{size}'>{escape(text)}</run>"


class Sheet:
    def __init__(self, name: str, src: str, title: str, subtitle: str = ""):
        self.name, self.src, self.title, self.subtitle = name, src, title, subtitle
        self.instances: dict[str, tuple[str, str, str]] = {}    # instance name -> (column, derivation, type)
        self.rows = self.cols = ""
        self.mark = "Automatic"
        self.encodings: list[tuple[str, str]] = []
        self.keeps: list[str] = []           # member filters (become context filters when a top-N filter exists)
        self.filters: list[str] = []
        self.slices: list[str] = []
        self.sorts: list[str] = []
        self.styles: list[str] = []          # worksheet style rules (colour maps, log axes, font size)
        self.label: list[str] = []           # customized label runs (BAN cards)
        self.mark_color = HILITE              # single-series marks: the highlight colour
        self.title_size = 11
        self.fit = "entire-view"             # fill the card; text lists use fit-width

    def f(self, agg: str, col: str, kind: str = "") -> str:
        """Reference a field: agg in none/sum/avg/med/tdy/tmn/usr; returns '[federated.x].[agg:col:kind]'."""
        if not kind:
            dt, role, typ, *_ = col_meta(self.src, col)
            if agg == "usr":
                kind = "nk" if dt == "string" else "qk"
            else:
                kind = "qk" if agg != "none" else ("ok" if typ == "ordinal" else "nk")
        inst = f"{agg}:{col}:{kind}"
        typ = {"qk": "quantitative", "ok": "ordinal", "nk": "nominal"}[kind]
        self.instances[inst] = (col, DERIV[agg], typ)
        return f"[{ds_name(self.src)}].[{inst}]"

    def keep(self, col: str, *members: str):
        ref = self.f("none", col)
        level = ref.split("].", 1)[1]
        if len(members) == 1:
            gf = (f"<groupfilter function='member' level='{level}' member='{q(members[0])}' "
                  f"user:ui-domain='database' user:ui-enumeration='inclusive' user:ui-marker='enumerate' />")
        else:
            inner = "".join(f"<groupfilter function='member' level='{level}' member='{q(m)}' />" for m in members)
            gf = (f"<groupfilter function='union' user:ui-domain='database' user:ui-enumeration='inclusive' "
                  f"user:ui-marker='enumerate'>{inner}</groupfilter>")
        self.keeps.append(f"<filter class='categorical' column='{ref}'{{ctx}}>{gf}</filter>")
        self.slices.append(ref)

    def top(self, col: str, n: int, expression: str):
        ref = self.f("none", col)
        level = ref.split("].", 1)[1]
        self.filters.append(
            f"<filter class='categorical' column='{ref}'>"
            f"<groupfilter count='{n}' end='top' function='end' units='records' user:ui-marker='end' "
            f"user:ui-top-by-field='true'><groupfilter direction='DESC' expression='{q(expression)}' "
            f"function='order'><groupfilter function='level-members' level='{level}' /></groupfilter>"
            f"</groupfilter></filter>")
        self.slices.append(ref)

    def color(self, ref: str, mapping: dict[str, str]):
        self.encodings.append(("color", ref))
        maps = "".join(f"<map to='{c}'><bucket>{q(chr(34) + k + chr(34))}</bucket></map>" for k, c in mapping.items())
        self.styles.append(f"<style-rule element='mark'><encoding attr='color' field='{ref}' type='palette'>"
                           f"{maps}</encoding></style-rule>")

    def log_axis(self, ref: str, scope: str):
        self.styles.append(f"<style-rule element='axis'><encoding attr='space' class='0' field='{ref}' "
                           f"field-type='quantitative' scale='log' scope='{scope}' type='space' /></style-rule>")

    def big_number(self, size: int = 28):
        self.styles.append(f"<style-rule element='cell'><format attr='font-size' value='{size}' />"
                           f"<format attr='font-weight' value='bold' /><format attr='color' value='{INK}' /></style-rule>")

    def ban(self, big: str, *small: str, size: int = 24):
        """A big-number card: one large value, then smaller lines underneath (customized label)."""
        self.mark = "Text"
        parts = [f"<run bold='true' fontcolor='{INK}' fontsize='{size}'>&lt;{big}&gt;</run>"]
        for ref in small:
            parts.append(f"<run>{NL}</run><run fontcolor='{INK2}' fontsize='10'>&lt;{ref}&gt;</run>")
        self.encodings += [("text", r) for r in (big, *small)]
        self.label = parts
        self.title_size = 10

    def sort_by(self, dim_ref: str, measure_ref: str, direction: str = "DESC"):
        self.sorts.append(f"<sort class='computed' column='{dim_ref}' direction='{direction}' using='{measure_ref}' />")

    def manual_sort(self, dim_ref: str, values: list[str]):
        buckets = "".join(f"<bucket>{q(chr(34) + v + chr(34))}</bucket>" for v in values)
        self.sorts.append(f"<sort class='manual' column='{dim_ref}' direction='ASC'><dictionary>{buckets}</dictionary>"
                          f"</sort>")

    def hide_headers(self):
        self.styles.append("<style-rule element='worksheet'><format attr='display-field-labels' scope='rows' "
                           "value='false' /><format attr='display-field-labels' scope='cols' value='false' /></style-rule>")

    def xml(self) -> str:
        used_cols = []

        def use(col: str):                   # a calculated field also needs the columns its formula uses
            if col in used_cols:
                return
            used_cols.append(col)
            formula = col_meta(self.src, col)[4]
            for ref in re.findall(r"\[([^\]]+)\]", formula or ""):
                use(ref)

        for col, _, _ in self.instances.values():
            use(col)
        deps = "".join(column_xml(self.src, c, "            ") for c in used_cols)
        deps += "".join(f"            <column-instance column='[{c}]' derivation='{d}' name='[{n}]' pivot='key' "
                        f"type='{t}' />\n" for n, (c, d, t) in self.instances.items())
        enc = "".join(f"<{k} column='{v}' />" for k, v in self.encodings)
        ctx = " context='true'" if self.filters else ""    # member filters first, then top N inside them
        keeps = [k.replace("{ctx}", ctx) for k in self.keeps]
        filters = "".join(f"          {x}\n" for x in keeps + self.filters + self.sorts)
        slices = ("          <slices>" + "".join(f"<column>{s}</column>" for s in self.slices) + "</slices>\n"
                  if self.slices else "")
        title = run(self.title, self.title_size, INK, bold=True)
        if self.subtitle:
            title += f"<run>{NL}</run>" + run(self.subtitle, 9, INK3)
        label = (f"<customized-label><formatted-text>{''.join(self.label)}</formatted-text></customized-label>"
                 if self.label else "")
        return f"""    <worksheet name='{q(self.name)}'>
      <layout-options>
        <title><formatted-text>{title}</formatted-text></title>
      </layout-options>
      <table>
        <view>
          <datasources>
            <datasource caption='{q(CAPTIONS[self.src])}' name='{ds_name(self.src)}' />
          </datasources>
          <datasource-dependencies datasource='{ds_name(self.src)}'>
{deps}          </datasource-dependencies>
{filters}{slices}          <aggregation value='true' />
        </view>
        <style>{THEME}{"".join(self.styles)}</style>
        <panes>
          <pane selection-relaxation-option='selection-relaxation-allow'>
            <view><breakdown value='auto' /></view>
            <mark class='{self.mark}' />
            <encodings>{enc}</encodings>
            {label}
            <style><style-rule element='mark'><format attr='mark-color' value='{self.mark_color}' /></style-rule></style>
          </pane>
        </panes>
        <rows>{escape(self.rows)}</rows>
        <cols>{escape(self.cols)}</cols>
      </table>
    </worksheet>
"""


sheets: list[Sheet] = []


def add(sheet: Sheet) -> Sheet:
    sheets.append(sheet)
    return sheet


def bar(name, src, title, subtitle, dim, measure, agg="med", color=None, sort=None, keep=(), top=None):
    """Horizontal bar chart: one bar per value of dim. color = (field, mapping); keep = [(col, member...)]."""
    s = add(Sheet(name, src, title, subtitle))
    d = s.f("none", dim)
    m = s.f(agg, measure)
    s.rows, s.cols, s.mark = d, m, "Bar"
    if color:
        field, mapping = color
        s.color(s.f("usr" if col_meta(src, field)[2] == "nominal" and col_meta(src, field)[1] == "measure"
                    else "none", field), mapping)
    for col, *members in keep:
        s.keep(col, *members)
    if top:
        s.top(dim, top[0], top[1])
    if sort == "value":
        s.sort_by(d, m)
    elif isinstance(sort, list):
        s.manual_sort(d, sort)
    return s


# ============================================================ sheets
WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
MATURE = ("is_mature", '"yes"')
INDEX_SUB = "median performance index (1 = typical for its time, 2+ = breakout); posts 14+ days old"

# ---- shared: daily Claude text (header + actions) and platform cards
s = add(Sheet("Headline summary", "insights", "Today in one sentence", "written every afternoon by Claude from the numbers"))
s.mark = "Text"
s.encodings.append(("text", s.f("none", "text")))
s.keep("slot", '"summary_headline"')
s.big_number(14)
s.title_size = 9

s = add(Sheet("Actions", "insights", "What to do next", "written daily by Claude from the data"))
s.rows, s.mark = s.f("none", "Calculation_501"), "Text"
s.encodings.append(("text", s.f("none", "text")))
s.keep("slot", '"action_1"', '"action_2"', '"action_3"')
s.styles.append("<style-rule element='cell'><format attr='font-size' value='13' /></style-rule>")
s.fit = "fit-width"
s.hide_headers()


def platform_card(name: str, title: str, *platforms: str) -> Sheet:
    s = add(Sheet(name, "scorecard", title))
    if len(platforms) > 1:
        p = s.f("none", "platform")
        s.cols = p
        s.manual_sort(p, list(platforms))
    s.ban(s.f("none", "Calculation_701"), s.f("none", "Calculation_702"), s.f("none", "Calculation_703"))
    s.keep("platform", *[f'"{x}"' for x in platforms])
    return s


# ---- Executive: plain words, numbers first (written for non-technical readers, see DASHBOARD_GUIDE.md)
for name, src, calc, title, sub in [
        ("Exec BAN followers", "scorecard", "Calculation_711", "Followers", "YouTube + TikTok + Instagram"),
        ("Exec BAN new followers", "scorecard", "Calculation_712", "New followers this week",
         "TikTok + Instagram (YouTube hides small changes)"),
        ("Exec BAN views", "scorecard", "Calculation_713", "Views this week", "YouTube + TikTok"),
        ("Exec BAN posts", "scorecard", "Calculation_714", "New posts this week", "all 3 platforms"),
        ("Exec BAN breakout", "tiktok", "Calculation_607", "TikTok posts that went big",
         "share of the last 30 days' posts with 2x normal views")]:
    s = add(Sheet(name, src, title, sub))
    s.mark = "Text"
    s.encodings.append(("text", s.f("usr", calc)))
    s.big_number(30)
    s.title_size = 11

s = add(Sheet("Exec platform table", "scorecard", "Each platform this week",
              "counted from our daily snapshots; Instagram hides views, so it counts likes"))
p = s.f("none", "platform")
s.rows = " / ".join([p] + [s.f("none", c) for c in
                           ("Calculation_701", "Calculation_702", "Calculation_703", "Calculation_706",
                            "Calculation_705")])
s.mark = "Text"
s.encodings.append(("text", s.f("none", "Calculation_704")))
s.manual_sort(p, ["YouTube", "TikTok", "Instagram"])
s.styles.append(f"<style-rule element='header'><format attr='font-size' value='12' />"
                f"<format attr='color' value='{INK}' /></style-rule>"
                f"<style-rule element='cell'><format attr='font-size' value='12' />"
                f"<format attr='color' value='{INK2}' /></style-rule>")
s.fit = "fit-width"

s = add(Sheet("Best post this week", "scorecard", "Best post this week, per platform",
              "most views gained (Instagram: likes) since the start of the window"))
s.rows = f"{s.f('none', 'platform')} / {s.f('none', 'Calculation_705')}"
s.mark = "Text"
s.encodings.append(("text", s.f("none", "Calculation_704")))
s.manual_sort(s.f("none", "platform"), ["YouTube", "TikTok", "Instagram"])
s.fit = "fit-width"

s = add(Sheet("Exec TikTok breakouts", "tiktok", "TikTok: how often a post goes big, by month",
              "% of each month's posts that got at least 2x the views of a normal post at that time; last 24 months"))
s.cols, s.rows, s.mark = s.f("tmn", "published_date_ph"), s.f("usr", "Calculation_602"), "Bar"
s.keep("Calculation_606", "true")

s = add(Sheet("Exec TikTok gainers", "tiktok", "TikTok: posts gaining the most views this week",
              "views gained since our first snapshot of the week (any post age)"))
d, m = s.f("none", "Calculation_605"), s.f("sum", "views_gained_7d")
s.rows, s.cols, s.mark = d, m, "Bar"
s.top("Calculation_605", 6, "SUM([views_gained_7d])")
s.sort_by(d, m)

# ---- TikTok (one chart per question, TIKTOK_QUESTIONS.md)
platform_card("TT card", "Followers and views this week", "TikTok")

s = add(Sheet("TT BAN breakout", "tiktok", "Breakout rate"))
s.ban(s.f("usr", "Calculation_607"), s.f("usr", "Calculation_608"))

s = add(Sheet("TT BAN share save", "tiktok", "Shares + saves"))
s.ban(s.f("usr", "Calculation_609"), s.f("usr", "Calculation_610"))

s = add(Sheet("TT Q14 index over time", "tiktok", "Q1 + Q14 · Is TikTok pushing our posts more or less often?",
              "each dot = one post; performance index = views / median of the 30 posts around it (log scale)"))
s.cols, s.rows, s.mark = s.f("tdy", "published_date_ph"), s.f("sum", "perf_index"), "Circle"
s.encodings.append(("lod", s.f("none", "video_id")))
s.encodings.append(("tooltip", s.f("none", "Calculation_605")))
s.color(s.f("none", "index_band"), BANDS)
s.log_axis(s.rows, "rows")

s = add(Sheet("TT Q1 breakouts by month", "tiktok", "Q1 · Share of posts that broke out (2x+), by month",
              "% of each month's posts with performance index 2 or more; last 24 months"))
s.cols, s.rows, s.mark = s.f("tmn", "published_date_ph"), s.f("usr", "Calculation_602"), "Bar"
s.keep("Calculation_606", "true")

bar("TT Q4 share save groups", "tiktok", "Q4 · Do shares and saves bring reach?",
    "posts split into 4 equal groups by shares + saves per 1,000 views; bar = median performance index",
    "share_save_group", "perf_index", color=("Calculation_601", VS_TYPICAL), keep=[MATURE])

bar("TT Q4 top shared", "tiktok", "Q4 · Most shared + saved posts (10k+ views)",
    "shares + saves per 1,000 views; open them and look for the shareable moment",
    "Calculation_605", "share_save_per_1k", agg="sum", sort="value", keep=[("Calculation_612", "true")],
    top=(10, "SUM([share_save_per_1k])"))

bar("TT Q5 comments", "tiktok", "Q5 · Do captions that ask a question get more comments?",
    "median comments per 1,000 views", "asks_question", "comments_per_1k")

bar("TT Q3 length", "tiktok", "Q3 · Which length works best?", INDEX_SUB + " (stand-in for watch time)",
    "length_group", "perf_index", color=("Calculation_601", VS_TYPICAL), keep=[MATURE])

bar("TT Q6 caption type", "tiktok", "Q6 · Which kinds of post beat the typical post?", INDEX_SUB,
    "caption_type", "perf_index", color=("Calculation_601", VS_TYPICAL), keep=[MATURE])

bar("TT Q7 sound", "tiktok", "Q7 · Original sound or the official track?",
    "median performance index, posts from the last 6 months only", "sound_type", "perf_index",
    color=("Calculation_601", VS_TYPICAL), keep=[("Calculation_603", "true")])

bar("TT Q15 hashtags", "hashtags", "Q15 · Which hashtags go with stronger posts?",
    "median performance index of posts using each tag (tags on 10+ posts); a label, not a cause",
    "hashtag", "median_index", agg="sum", sort="value", color=("Calculation_801", VS_TYPICAL),
    top=(15, "SUM([videos])"))

bar("TT Q15 tag count", "tiktok", "Q15 · How many hashtags?", INDEX_SUB, "hashtag_group", "perf_index",
    color=("Calculation_601", VS_TYPICAL), keep=[MATURE])

bar("TT Q11 time", "tiktok", "Q11 · Post time (PH)", INDEX_SUB, "time_window", "perf_index",
    color=("Calculation_601", VS_TYPICAL), keep=[MATURE])

bar("TT Q11 weekday", "tiktok", "Q11 · Weekday", INDEX_SUB, "weekday_ph", "perf_index",
    color=("Calculation_601", VS_TYPICAL), keep=[MATURE], sort=WEEKDAYS)

bar("TT Q11 posts per day", "tiktok", "Q11 · Posts on the same day", INDEX_SUB, "Calculation_604", "perf_index",
    color=("Calculation_601", VS_TYPICAL), keep=[MATURE])

bar("TT Q10 comebacks", "tiktok", "Q10 · Older posts still gaining views",
    "views gained in the last 7 days, posts older than 30 days (TikTok rounds big counts)",
    "Calculation_605", "views_gained_7d", agg="sum", sort="value", keep=[("Calculation_611", "true")],
    top=(10, "SUM([views_gained_7d])"))

s = bar("TT best recent", "tiktok", "Best posts of the last 30 days", "performance index (2+ = breakout)",
        "Calculation_605", "perf_index", agg="sum", sort="value", keep=[("is_last_30d", '"yes"')],
        top=(10, "SUM([perf_index])"))
s.color(s.f("none", "index_band"), BANDS)

# ---- YouTube (simple version)
platform_card("YT card", "Subscribers and views this week", "YouTube")

s = add(Sheet("YT top videos", "video", "Top 10 videos by views per day since upload",
              "views per day is fair between old and new videos"))
d, m = s.f("none", "Calculation_201"), s.f("sum", "views_per_day")
s.rows, s.cols, s.mark = d, m, "Bar"
s.keep("platform", '"YouTube"')
s.top("Calculation_201", 10, "SUM([views_per_day])")
s.sort_by(d, m)

s = add(Sheet("YT views by series", "video", "Total views by series"))
d, m = s.f("none", "series"), s.f("sum", "latest_views")
s.rows, s.cols, s.mark = d, m, "Bar"
s.color(s.f("none", "Calculation_303"), {"Live at The Cozy Cove": HILITE, "Other series": MUTED})
s.keep("platform", '"YouTube"')
s.sort_by(d, m)

bar("YT weekday", "video", "Median views per day by upload weekday", "full videos only",
    "published_weekday_ph", "views_per_day", keep=[("platform", '"YouTube"'), ("format", '"Full video"')],
    sort=WEEKDAYS)

bar("YT format", "video", "Full sessions vs Shorts", "median views per day since upload",
    "format", "views_per_day", keep=[("platform", '"YouTube"')], sort="value")

# ---- Instagram (simple version; no views in the public API, so likes)
platform_card("IG card", "Followers and likes this week", "Instagram")

s = add(Sheet("IG top posts", "video", "Top 10 posts by likes per day since posting"))
d, m = s.f("none", "Calculation_201"), s.f("sum", "likes_per_day")
s.rows, s.cols, s.mark = d, m, "Bar"
s.keep("platform", '"Instagram"')
s.top("Calculation_201", 10, "SUM([likes_per_day])")
s.sort_by(d, m)

bar("IG format", "video", "Reels vs posts vs carousels", "median likes per day since posting",
    "format", "likes_per_day", keep=[("platform", '"Instagram"')], sort="value")

s = add(Sheet("IG followers", "account", "Followers since tracking began", "real daily snapshots"))
s.cols, s.rows, s.mark = s.f("tdy", "snapshot_date"), s.f("sum", "followers"), "Line"
s.keep("platform", '"Instagram"')
s.keep("data_source", '"real"')
s.mark_color = AQUA


# ============================================================ dashboards (sizes and zones in pixels)
CARD = (f"<zone-style><format attr='background-color' value='{CARD_BG}' /><format attr='margin' value='4' />"
        f"<format attr='padding' value='8' /></zone-style>")
W = 1200


def title_text(title: str, sub: str) -> str:
    return run(title, 20, INK, bold=True) + f"<run>{NL}</run>" + run(sub, 10, INK3)


def section(title: str, sub: str = "") -> str:
    return run(title, 13, INK, bold=True) + (run("   " + sub, 10, INK3) if sub else "")


NOT_YET = [
    ("Q2  How fast does a new post take off?", "needs ~5 weeks of daily snapshots (tracking began 13 Oct)"),
    ("Q8  Do captions naming the song keep earning views?", "needs ~6 weeks of daily snapshots"),
    ("Q9  Which posts bring followers?", "rough split possible now; solid answer in ~4 weeks"),
    ("Q12  Are other people using NDN sounds?", "new data: sound-page counts"),
    ("Q13  Does a TikTok spike lead Spotify / YouTube?", "needs kworb (Spotify) data, then 6-8 weeks"),
    ("Q16  Do trends lift a post?", "new data: TikTok Creative Center weekly snapshot"),
    ("Q17  What to post next week", "written by the daily routine once the answers above are in"),
    ("Watch time, completion, traffic source", "Phase 2: only with NDN's own TikTok Studio"),
]
not_yet = "".join(run(q_, 10, INK, bold=True) + run("   " + why, 10, INK3) + f"<run>{NL}</run>" for q_, why in NOT_YET)
HOW_TO_READ = ("How to read this page: every comparison uses the performance index = a post's views ÷ the median "
               "views of the 30 NDN posts published around it. 1.0 = typical for its time, 2.0+ = breakout. "
               "White bars beat the typical post, gray bars fall short. Goal: more views per post.")

# zone = (sheet name or "text:<formatted runs>", x, y, w, h, card?)
DASHBOARDS = [
    ("0 Executive", 1600, 1000, [
        ("text:" + title_text("Nine Degrees North", "Social media this week: YouTube, TikTok and Instagram. "
                              "Updated every day from public numbers."), 0, 0, 1600, 64, False),
        ("Headline summary", 0, 64, 1600, 86, True),
        ("Exec BAN followers", 0, 150, 320, 120, True),
        ("Exec BAN new followers", 320, 150, 320, 120, True),
        ("Exec BAN views", 640, 150, 320, 120, True),
        ("Exec BAN posts", 960, 150, 320, 120, True),
        ("Exec BAN breakout", 1280, 150, 320, 120, True),
        ("Exec platform table", 0, 270, 1600, 190, True),
        ("Actions", 0, 460, 1600, 170, True),
        ("Exec TikTok breakouts", 0, 630, 900, 330, True),
        ("Exec TikTok gainers", 900, 630, 700, 330, True),
    ]),
    ("1 TikTok", 1200, 2900, [
        ("text:" + title_text("TikTok · How do we get more views?",
                              "One chart per question from our TikTok research (how the algorithm ranks posts)."),
         0, 0, W, 60, False),
        ("text:" + run(HOW_TO_READ, 10, INK2), 0, 60, W, 60, True),
        ("TT card", 0, 120, 600, 140, True),
        ("TT BAN breakout", 600, 120, 300, 140, True),
        ("TT BAN share save", 900, 120, 300, 140, True),
        ("text:" + section("ATTRACT", "Is TikTok showing our posts to new people?"), 0, 260, W, 40, False),
        ("TT Q14 index over time", 0, 300, 720, 340, True),
        ("TT Q1 breakouts by month", 720, 300, 480, 340, True),
        ("text:" + section("ENGAGE + RETAIN", "Shares and saves send a post to new people; watch time keeps it there."),
         0, 640, W, 40, False),
        ("TT Q4 share save groups", 0, 680, 420, 300, True),
        ("TT Q4 top shared", 420, 680, 780, 300, True),
        ("TT Q5 comments", 0, 980, 420, 240, True),
        ("TT Q3 length", 420, 980, 780, 240, True),
        ("text:" + section("RELEVANCE", "Captions, sounds and hashtags tell TikTok who to test a post on."),
         0, 1220, W, 40, False),
        ("TT Q6 caption type", 0, 1260, 600, 260, True),
        ("TT Q7 sound", 600, 1260, 600, 260, True),
        ("TT Q15 hashtags", 0, 1520, 600, 380, True),
        ("TT Q15 tag count", 600, 1520, 600, 380, True),
        ("text:" + section("HABITS + LONG LIFE", "What NDN controls, and which posts keep working."),
         0, 1900, W, 40, False),
        ("TT Q11 time", 0, 1940, 400, 260, True),
        ("TT Q11 weekday", 400, 1940, 400, 260, True),
        ("TT Q11 posts per day", 800, 1940, 400, 260, True),
        ("TT Q10 comebacks", 0, 2200, 600, 360, True),
        ("TT best recent", 600, 2200, 600, 360, True),
        ("text:" + section("NOT ANSWERABLE YET", "what each open question still needs"), 0, 2560, W, 40, False),
        ("text:" + not_yet, 0, 2600, W, 260, True),
    ]),
    ("2 YouTube", 1200, 800, [
        ("text:" + title_text("YouTube · Sessions that last", "Simple version; YouTube's own question list comes next."),
         0, 0, W, 60, False),
        ("YT card", 0, 60, 600, 140, True),
        ("Best post this week", 600, 60, 600, 140, True),
        ("YT top videos", 0, 200, 600, 300, True),
        ("YT views by series", 600, 200, 600, 300, True),
        ("YT weekday", 0, 500, 600, 260, True),
        ("YT format", 600, 500, 600, 260, True),
    ]),
    ("3 Instagram", 1200, 800, [
        ("text:" + title_text("Instagram · Reels and posts",
                              "Simple version; Instagram hides views, so this page uses likes."), 0, 0, W, 60, False),
        ("IG card", 0, 60, 600, 140, True),
        ("IG followers", 600, 60, 600, 300, True),
        ("IG format", 0, 200, 600, 160, True),
        ("IG top posts", 0, 360, W, 400, True),
    ]),
]


def dashboard_xml(name: str, width: int, height: int, zones: list) -> str:
    zid = iter(range(2, 200))
    sx, sy = 100000 / width, 100000 / height
    inner = ""
    for n, x, y, w, h, card in zones:
        pos = f"h='{round(h * sy)}' w='{round(w * sx)}' x='{round(x * sx)}' y='{round(y * sy)}'"
        style = CARD if card else ""
        if n.startswith("text:"):
            inner += (f"          <zone {pos} id='{next(zid)}' type-v2='text'>"
                      f"<formatted-text>{n[5:]}</formatted-text>{style}</zone>\n")
        else:
            inner += f"          <zone {pos} id='{next(zid)}' name='{q(n)}'>{style}</zone>\n"
    fy = height - 40
    inner += (f"          <zone h='{round(40 * sy)}' id='{next(zid)}' type-v2='text' w='100000' x='0' "
              f"y='{round(fy * sy)}'><formatted-text>{run(NOTE, 8, INK3)}</formatted-text></zone>\n")
    return f"""    <dashboard name='{q(name)}'>
      <style><style-rule element='table'><format attr='background-color' value='{PAGE_BG}' /></style-rule></style>
      <size maxheight='{height}' maxwidth='{width}' minheight='{height}' minwidth='{width}' />
      <zones>
        <zone h='100000' id='1' type-v2='layout-basic' w='100000' x='0' y='0'>
{inner}        </zone>
      </zones>
    </dashboard>
"""


CARDS = """      <cards>
        <edge name='left'>
          <strip size='160'><card type='pages' /><card type='filters' /><card type='marks' /></strip>
        </edge>
        <edge name='top'>
          <strip size='2147483647'><card type='columns' /></strip>
          <strip size='2147483647'><card type='rows' /></strip>
          <strip size='31'><card type='title' /></strip>
        </edge>
      </cards>
"""


def dashboard_window(i: int, name: str, zones: list, device_preview: bool) -> str:
    maxed = " maximized='true'" if i == 0 else ""
    fits = {s.name: s.fit for s in sheets}
    names = [z[0] for z in zones if not z[0].startswith("text:")]
    points = "".join(f"<viewpoint name='{q(n)}'><zoom type='{fits.get(n, 'entire-view')}' /></viewpoint>" for n in names)
    dp = "<device-preview />" if device_preview else ""
    return f"    <window class='dashboard'{maxed} name='{q(name)}'><viewpoints>{points}</viewpoints><active id='-1' />{dp}</window>\n"


def workbook_xml(use_sheets: list, dashboards: list, device_preview: bool = True) -> str:
    sources = {s.src for s in use_sheets}
    windows = "".join(dashboard_window(i, n, z, device_preview) for i, (n, _, _, z) in enumerate(dashboards))
    hide = " hidden='true'" if dashboards else ""    # sheets live on dashboards: keep the tabs clean
    windows += "".join(f"    <window class='worksheet'{hide} name='{q(s.name)}'>\n{CARDS}      <viewpoint><zoom type='{s.fit}' /></viewpoint>\n    </window>\n" for s in use_sheets)
    dash = ("  <dashboards>\n" + "".join(dashboard_xml(*d) for d in dashboards) + "  </dashboards>\n"
            if dashboards else "")
    return ("<?xml version='1.0' encoding='utf-8' ?>\n"
            "<workbook source-build='2024.1.0 (20241.24.0312.0830)' source-platform='win' version='18.1' "
            "xmlns:user='http://www.tableausoftware.com/xml/user'>\n"
            "  <datasources>\n" + "".join(datasource_xml(x) for x in SOURCES if x in sources) + "  </datasources>\n"
            "  <worksheets>\n" + "".join(s.xml() for s in use_sheets) + "  </worksheets>\n"
            + dash +
            "  <windows source-height='30'>\n" + windows + "  </windows>\n"
            "</workbook>\n")


HYPER_TYPES = {"string": SqlType.text(), "integer": SqlType.big_int(), "real": SqlType.double(),
               "date": SqlType.date()}


def build_extracts(used: set[str]) -> dict[str, Path]:
    """Load each CSV into its own .hyper file, table "Extract"."Extract" (the name Tableau expects)."""
    paths = {}
    with HyperProcess(Telemetry.DO_NOT_SEND_USAGE_DATA_TO_TABLEAU) as hyper:
        for src in used:
            csv, cols, _ = SOURCES[src]
            path = BASE / "tableau" / "extracts" / f"{src}.hyper"
            path.parent.mkdir(exist_ok=True)
            table = TableDefinition(TableName("Extract", "Extract"),
                                    [TableDefinition.Column(n, HYPER_TYPES[dt]) for n, dt, _, _ in cols])
            with Connection(hyper.endpoint, path, CreateMode.CREATE_AND_REPLACE) as conn:
                conn.catalog.create_schema("Extract")
                conn.catalog.create_table(table)
                rows = conn.execute_command(
                    f"COPY {table.table_name} FROM {escape_string_literal(str(BASE / 'tableau' / csv))} "
                    f"WITH (format csv, NULL '', delimiter ',', header)")
            print(f"{src:10} {rows:>6,} rows -> {path.name}")
            paths[src] = path
    return paths


def write_twbx(path: Path, xml: str, extracts: dict[str, Path]):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(path.with_suffix(".twb").name, xml)
        for src, p in extracts.items():
            z.write(p, f"Data/Extracts/{src}.hyper")


if __name__ == "__main__":
    on_dash = {z[0] for *_, zones in DASHBOARDS for z in zones}
    missing = [s.name for s in sheets if s.name not in on_dash]
    unknown = [n for n in on_dash if not n.startswith("text:") and n not in {s.name for s in sheets}]
    assert not unknown, f"dashboard zones without a sheet: {unknown}"
    if missing:
        print("sheets not on any dashboard:", missing)
    used = {s.src for s in sheets}
    extracts = build_extracts(used)
    write_twbx(OUT, workbook_xml(sheets, DASHBOARDS), extracts)
    print(f"wrote {OUT} ({len(sheets)} sheets, {len(DASHBOARDS)} dashboards)")
