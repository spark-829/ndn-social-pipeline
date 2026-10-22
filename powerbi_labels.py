"""Plain-language names and hover help for the NDN Power BI report (Vic 2026-10-22: the readers are not data people).

COLUMNS["table.column"] and MEASURES["measure name"] = (plain name or None, help).
- The plain name is what tables, axes and data tooltips show when build_powerbi.py gives no label of its own.
- The help says what the number means and where it comes from. It becomes the field's description in the model
  (hover in the Fields pane) and one line of the "?" tooltip in the corner of every visual that shows the field.
Keep the names free of jargon (median, index, percentile, log); the exact definition goes in the help.
build_powerbi.py stops if any model column or measure has no help here.
"""
PLATFORMS = ["TikTok", "YouTube", "Instagram"]
DAILY = "daily public count, 9 am PH"
STANDING = "a 0-100 score against all artists checked"    # explained in full once, in invite.score

COLUMNS = {
    # dim_platform
    "dim_platform.platform": ("Platform", "TikTok, YouTube or Instagram."),
    "dim_platform.sort_order": (None, "Puts the platforms in the order TikTok, YouTube, Instagram."),
    "dim_platform.hex_color": (None, "The platform's colour on every chart."),

    # dim_video: one row per NDN post on every platform
    "dim_video.platform": ("Platform", "TikTok, YouTube or Instagram."),
    "dim_video.video_id": ("Post ID", "The platform's own ID for the post."),
    "dim_video.title": ("Video", "Title (YouTube) or caption (TikTok, Instagram) as posted, cut to 160 characters."),
    "dim_video.url": ("Link", "Web address of the post."),
    "dim_video.published_ph": ("Posted at", "Date and time the post went up, Philippine time."),
    "dim_video.published_date_ph": ("Posted", "Day the post went up, Philippine time."),
    "dim_video.published_weekday_ph": ("Weekday posted", "Day of the week the post went up, Philippine time."),
    "dim_video.published_weekday_num": (None, "Only used to put the weekdays in order."),
    "dim_video.published_hour_ph": ("Hour posted", "Hour of the day the post went up (0-23), Philippine time."),
    "dim_video.upload_slot": ("Upload time", "'7 pm' = NDN's usual 7 pm PH slot; 'Other times' = any other hour."),
    "dim_video.duration_sec": ("Length (seconds)", "Video length from the platform (Instagram doesn't share it)."),
    "dim_video.video_format": ("Format", "Full video, YouTube Short (60 s or less), TikTok clip, or Instagram Reel, "
                                          "post or carousel, from the platform's own data."),
    "dim_video.series": ("Series", "The NDN show the post belongs to (e.g. Live at The Cozy Cove), read from the title."),
    "dim_video.song": ("Song", "Song in the post, read from the title or caption."),
    "dim_video.artist": ("Artist", "Artist in the post, read from the title or caption."),
    "dim_video.latest_views": ("Views so far", f"All views at the latest {DAILY}. Instagram's number includes Facebook "
                                               "views since April 2026."),
    "dim_video.latest_likes": ("Likes so far", f"All likes at the latest {DAILY}."),
    "dim_video.latest_comments": ("Comments so far", f"All comments at the latest {DAILY}."),
    "dim_video.latest_snapshot": ("Last counted", "Day of the latest daily count."),
    "dim_video.age_days": ("Days online", "Days between posting and the latest count."),
    "dim_video.age_band": ("Age", "How old the post is: under 30 days, 1-3 months, 3-12 months, 1-2 years, over 2 years."),
    "dim_video.views_per_day": ("Views per day", "Views so far ÷ days online, so new and old posts compare fairly."),
    "dim_video.likes_per_day": ("Likes per day", "Likes so far ÷ days online, so new and old posts compare fairly."),
    "dim_video.perf_per_day": ("Views per day (likes on Instagram)",
                               "Views so far ÷ days online; likes for Instagram photos, which have no public views."),
    "dim_video.engagement_rate": ("Likes + comments per view",
                                  "(Likes + comments) ÷ views so far. 3% = 3 likes or comments for every 100 views."),
    "dim_video.vs_series_median": ("Compared with its series",
                                   "Views per day ÷ views per day of the middle video in the same series. "
                                   "1.0 = usual for the series, 2.0 = twice as good."),
    "dim_video.views_gained_7d": ("Views gained, last 7 days", "Views added over the last 7 daily counts."),
    "dim_video.likes_gained_7d": ("Likes gained, last 7 days", "Likes added over the last 7 daily counts."),
    "dim_video.artist_monthly_listeners": ("Artist's Spotify monthly listeners",
                                           "People who played the artist on Spotify in the last 28 days (Spotify "
                                           "artist page, read weekly). Shows how big the artist is."),
    "dim_video.song_spotify_streams": ("Song's Spotify plays",
                                       "All-time Spotify plays of the studio version of the song (kworb.net, weekly)."),
    "dim_video.ig_caption_type": ("Caption type", "What the Instagram caption announces: Premiere teaser, now "
                                                  "streaming, event / tickets, performance clip or other."),
    "dim_video.ig_hashtags": ("Hashtags", "Number of hashtags in the Instagram caption."),
    "dim_video.ig_reposts": ("Reposts", "Times people reposted the post to their own profile (public Instagram count)."),
    "dim_video.reposts_per_1k_views": ("Reposts per 1,000 views", "Reposts ÷ views × 1,000. Shares and saves are "
                                                                  "private on Instagram, so reposts stand in for them."),
    "dim_video.comments_per_1k_likes": ("Comments per 1,000 likes", "Comments ÷ likes × 1,000: how much talk a post "
                                                                    "starts for its size."),
    "dim_video.ig_hashtag_group": ("Hashtags used", "Hashtags in the caption, grouped: 0, 1-3, 4-5, 6 or more."),

    # account_daily / platform_daily / scorecard
    "account_daily.platform": ("Platform", "TikTok, YouTube or Instagram."),
    "account_daily.snapshot_date": ("Day", "Day of the daily count (9 am PH)."),
    "account_daily.data_source": ("Real or made-up", "'real' = counted on the platform that day; 'synthetic' = made-up "
                                                     "test history, labelled and left out of this report."),
    "account_daily.followers": ("Followers", f"Followers at the {DAILY} (YouTube: subscribers, rounded by YouTube)."),
    "account_daily.followers_gained": ("Followers gained", "Change since the day before."),
    "account_daily.total_views": ("Total views", f"Views of all the account's posts at the {DAILY}."),
    "account_daily.views_gained": ("Views gained", "Change since the day before."),
    "account_daily.video_count": ("Posts", "Posts on the account that day."),
    "account_daily.hearts": ("TikTok likes", "All likes ('hearts') on the TikTok account, from its public profile."),
    "platform_daily.platform": ("Platform", "TikTok, YouTube or Instagram."),
    "platform_daily.snapshot_date": ("Day", "Day of the daily count (9 am PH)."),
    "platform_daily.data_source": ("Real or made-up", "'real' = counted on the platform that day; 'synthetic' = "
                                                      "made-up test history, left out of this report."),
    "platform_daily.views_gained": ("Views gained that day", "Views added since the day before, all posts added up."),
    "platform_daily.likes_gained": ("Likes gained that day", "Likes added since the day before, all posts added up."),
    "platform_daily.videos": ("Posts counted", "Posts counted that day."),
    "scorecard.platform": ("Platform", "TikTok, YouTube or Instagram."),
    "scorecard.as_of": ("As of", "Day of the latest real daily count."),
    "scorecard.window_days": ("Days compared", "How many days the change covers (about a week)."),
    "scorecard.metric_name": ("Counted", "'views', or 'likes' for Instagram (photos have no public views)."),
    "scorecard.followers": ("Followers", f"Followers at the latest {DAILY}."),
    "scorecard.followers_change": ("Follower change", "Followers now minus followers at the start of those days."),
    "scorecard.followers_change_pct": ("Follower change %", "Follower change ÷ followers at the start × 100."),
    "scorecard.metric_gained": ("Views gained (likes on Instagram)", "Added up over all posts in those days."),
    "scorecard.posts_in_window": ("New posts", "Posts that went up in those days."),
    "scorecard.best_post": ("Best post", "The post that gained the most views (likes on Instagram) in those days."),
    "scorecard.best_post_url": ("Link", "Web address of the best post."),
    "scorecard.best_post_gained": ("Gained", "Views (likes on Instagram) the best post gained in those days."),

    # tiktok_video
    "tiktok_video.video_id": ("Post ID", "TikTok's own ID for the video."),
    "tiktok_video.url": ("Link", "Web address of the TikTok."),
    "tiktok_video.caption": ("Caption", "The TikTok caption, cut to 90 characters."),
    "tiktok_video.published_date_ph": ("Posted", "Day the TikTok went up, Philippine time."),
    "tiktok_video.published_month": ("Month posted", "Month the TikTok went up."),
    "tiktok_video.published_year": ("Year posted", "Year the TikTok went up."),
    "tiktok_video.weekday_ph": ("Weekday posted", "Day of the week the TikTok went up, Philippine time."),
    "tiktok_video.weekday_num": (None, "Only used to put the weekdays in order."),
    "tiktok_video.hour_ph": ("Hour posted", "Hour of the day the TikTok went up (0-23), Philippine time."),
    "tiktok_video.time_window": ("Time of day", "When it went up, PH time: morning 5-11, afternoon 12-16, "
                                                "evening 17-21, late night 22-4."),
    "tiktok_video.posts_that_day": ("NDN TikToks that day", "How many TikToks NDN posted that same day (4+ = four or more)."),
    "tiktok_video.duration_sec": ("Length (seconds)", "Video length from TikTok."),
    "tiktok_video.length_group": ("Length", "Video length: under 15 s, 15-30 s, 31-60 s, over 60 s."),
    "tiktok_video.views": ("Views", f"Views at the latest {DAILY}."),
    "tiktok_video.likes": ("Likes", f"Likes at the latest {DAILY}."),
    "tiktok_video.comments": ("Comments", f"Comments at the latest {DAILY}."),
    "tiktok_video.shares": ("Shares", f"Shares at the latest {DAILY}."),
    "tiktok_video.saves": ("Saves", f"Saves (bookmarks) at the latest {DAILY}."),
    "tiktok_video.age_days": ("Days online", "Days between posting and the latest count."),
    "tiktok_video.age_band": ("Age", "How old the video is: under 30 days, 1-3 months, 3-12 months, 1-2 years, over 2 years."),
    "tiktok_video.is_mature": ("Online 14+ days", "yes = online for 14 days or more, so its views have mostly settled."),
    "tiktok_video.is_last_30d": ("Posted in the last 30 days", "yes = went up in the 30 days before the latest count."),
    "tiktok_video.likes_per_1k": ("Likes per 1,000 views", "Likes ÷ views × 1,000."),
    "tiktok_video.comments_per_1k": ("Comments per 1,000 views", "Comments ÷ views × 1,000."),
    "tiktok_video.shares_per_1k": ("Shares per 1,000 views", "Shares ÷ views × 1,000."),
    "tiktok_video.saves_per_1k": ("Saves per 1,000 views", "Saves ÷ views × 1,000."),
    "tiktok_video.share_save_per_1k": ("Shares + saves per 1,000 views",
                                       "(Shares + saves) ÷ views × 1,000. TikTok reads shares and saves as strong "
                                       "signs that people value a video, so they help it travel."),
    "tiktok_video.neighbour_median": ("Usual views at the time", "Middle views of the 30 NDN TikToks posted closest "
                                                                 "in time to this one."),
    "tiktok_video.perf_index": ("Views compared with usual",
                                "Views ÷ the usual views of the 30 NDN TikToks posted around it. 1.0 = usual, "
                                "2.0 = twice (a breakout). Comparing with nearby posts keeps old and new videos fair."),
    "tiktok_video.index_band": ("Compared with usual", "Breakout (2x the usual or more), above usual (1-2x) or below usual."),
    "tiktok_video.views_gained_7d": ("Views gained, last 7 days", "Views added over the last 7 daily counts."),
    "tiktok_video.gained_7d_per_1k": ("Views gained last week per 1,000 so far",
                                      "Views gained in the last 7 days ÷ views so far × 1,000. Higher = still being found."),
    "tiktok_video.caption_type": ("Clip type", "What the clip is, read from the caption: Premiere teaser, out now / "
                                               "stream, event / tickets, song clip with the title, or other talk."),
    "tiktok_video.asks_question": ("Caption asks a question", "yes = the caption asks viewers something."),
    "tiktok_video.n_hashtags": ("Hashtags", "Number of hashtags in the caption."),
    "tiktok_video.hashtag_group": ("Hashtags used", "Hashtags in the caption, grouped: 0, 1-3, 4-5, 6 or more."),
    "tiktok_video.sound_type": ("Sound", "'Original sound' = NDN's own audio from the session; 'Named track' = the "
                                         "official song from TikTok's music library."),
    "tiktok_video.song": ("Song", "Song in the clip, read from the caption."),
    "tiktok_video.artist": ("Artist", "Artist in the clip, read from the caption."),
    "tiktok_video.series": ("Series", "The NDN show the clip comes from."),
    "tiktok_video.sound_uses": ("Videos using its sound", "Videos by anyone on TikTok made with this post's NDN sound "
                                                          "(number on the sound page, latest weekly count)."),

    # tiktok_hashtag
    "tiktok_hashtag.hashtag": ("Hashtag", "A hashtag NDN used on 10 or more TikToks."),
    "tiktok_hashtag.videos": ("Videos", "NDN TikToks with this hashtag."),
    "tiktok_hashtag.median_index": ("Views compared with usual", "The middle video with this tag: views ÷ usual views "
                                                                 "of the posts around it. 1.0 = usual."),
    "tiktok_hashtag.breakout_pct": ("Share that broke out", "% of these videos with twice the usual views or more."),
    "tiktok_hashtag.median_views": ("Usual views", "Middle views of these videos: half got more, half fewer."),

    # insights
    "insights.as_of": ("Written on", "Day the sentences were written."),
    "insights.slot": ("Place on the page", "Which line of the Overview the sentence fills."),
    "insights.sort_order": (None, "Only used to order the sentences."),
    "insights.sentence": ("Sentence", "Written at 3 pm PH by a Claude routine from that day's numbers only."),

    # fan_demand / fan_upload
    "fan_demand.artist": ("Artist", "Artist named in comments asking NDN to feature them."),
    "fan_demand.status": ("Status", "'Never on NDN' = not filmed by NDN yet; 'Played for NDN' = filmed before."),
    "fan_demand.fans": ("Fans asking", "Different people asking for this artist in NDN's YouTube and TikTok comments, "
                                       "last 12 months. One person asking 5 times counts once."),
    "fan_demand.invite_fans": ("Fans asking to invite", "People asking NDN to invite the artist or pair them with another."),
    "fan_demand.more_fans": ("Fans asking for more", "People asking for another song or an upload by this artist."),
    "fan_demand.youtube_asks": ("YouTube asks", "Comments on NDN's YouTube asking for this artist (one person can ask "
                                                "more than once). Comments are read every week."),
    "fan_demand.tiktok_asks": ("TikTok asks", "Comments on NDN's TikTok asking for this artist. Read every week."),
    "fan_demand.fans_per_1000_comments": ("Fans asking per 1,000 comments",
                                          "Fans asking ÷ all NDN comments read × 1,000, so it stays fair as comments grow."),
    "fan_demand.latest_ask": ("Latest ask", "Day of the most recent comment asking for them."),
    "fan_demand.last_ndn_post": ("Last NDN post", "Latest NDN post featuring this artist."),
    "fan_demand.cooling_down": ("Cooling down", "yes = played for NDN in the last 10 months, so not suggested again yet."),
    "fan_upload.artist": ("Artist", "Artist whose filmed NDN session fans want posted or released."),
    "fan_upload.fans": ("Fans asking", "Different people asking, YouTube + TikTok comments."),
    "fan_upload.asks": ("Asks", "Comments asking NDN to upload the session or put it on streaming."),
    "fan_upload.asks_for_streaming": ("Want it on streaming", "Of those, comments asking for it on Spotify or other "
                                                              "streaming apps."),
    "fan_upload.latest_ask": ("Latest ask", "Day of the most recent such comment."),
    "fan_upload.top_ask": ("Example comment", "One real comment, cut to 140 characters."),

    # invite (sql/026, mart.invite_candidates)
    "invite.artist": ("Artist", "Spotify artist name; 4 letters of the Spotify ID are added when two artists share a name."),
    "invite.status": ("Group", "Recommend = who to invite (never played for NDN); Post or boost = NDN has the song "
                               "on YouTube, or the band played for NDN before."),
    "invite.hit_status": ("Song status", "New hit not on NDN / Hit already on NDN / Played for NDN, song not filmed."),
    "invite.new_hit_on_ndn": ("Song on NDN", "yes = NDN already has the hot song on YouTube."),
    "invite.action": ("What to do", "Invite / boost the NDN video of this song / post the band's clips or film this song."),
    "invite.ndn_video_title": ("NDN video to boost", "NDN's YouTube video of this song; if none, the band's most viewed "
                                                     "NDN video."),
    "invite.ndn_video_link": ("Open it", "Link to that NDN YouTube video."),
    "invite.ndn_video_views": ("Its views", "Views of that NDN video (latest daily count)."),
    "invite.ndn_history": ("NDN history", "'New to NDN' or 'Played for NDN' before."),
    "invite.found_via": ("Found via", "How the artist got on the list: an NDN artist or Vic's list, Spotify's "
                                      "Philippines weekly chart, or Spotify's Viral Hits Philippines playlist."),
    "invite.on_chart": ("On the Spotify PH chart", "yes = on Spotify's Philippines weekly top 200 in the last 8 weeks."),
    "invite.status_rank": ("Place in its group", "Place by invite score within its status group (1 = best)."),
    "invite.score": ("Invite score (0-100)", "The nine parts added up with their weights: TikTok 55, Spotify 30, "
                                             "other 15. Each part scores 0-100 against all artists checked "
                                             "(100 = top, 50 = middle, no data = 0). Higher = better to invite now."),
    "invite.tiktok_points": ("TikTok points (of 55)", "The four TikTok parts after weighting."),
    "invite.spotify_points": ("Spotify points (of 30)", "The three Spotify parts after weighting."),
    "invite.other_points": ("Other points (of 15)", "Fan requests and artist size after weighting."),
    "invite.tt_song_videos": ("TikTok videos using the new song",
                              f"All TikTok videos using the new song (its official sound plus versions found by searching "
                              f"its title on TikTok every 3 days), as {STANDING}. Weight 25%."),
    "invite.new_hit_tiktok_added_7d": ("TikTok videos added in 7 days",
                                       "New TikTok videos using the song in about a week: this week's count minus last "
                                       "week's, over the official sound and fan uploads that pass the caption check. "
                                       "Empty until two weekly counts exist."),
    "invite.tt_song_basis": ("What the TikTok part ranks", "All TikTok videos so far (sql/029)."),
    "invite.new_hit_top30_rank": ("OPM top 30 place", "The new song's place in the OPM top 30 (Top 50 PH + Viral Hits PH "
                                                      "+ Billboard PH Hot 100)."),
    "invite.new_hit_top30_points": ("List points", "The new song's points over the three lists (most = 300)."),
    "invite.new_hit_top50_pos": ("Top 50 PH", "The new song's place on Spotify's Top 50 - Philippines."),
    "invite.new_hit_viral_pos": ("Viral Hits PH", "The new song's place on Viral Hits Philippines."),
    "invite.new_hit_billboard_pos": ("Billboard PH Hot 100", "The new song's place on the Billboard Philippines Hot 100."),
    "invite.tt_song_growth": ("Growth of those videos",
                              f"How fast those videos grew over 4 weeks, as {STANDING}. Weight 15%. "
                              "0 for everyone until the second weekly count (Mon 26 Oct 2026)."),
    "invite.tt_follower_growth": ("Artist's TikTok follower growth",
                                  f"Follower growth of the artist's TikTok over 4 weeks (public profile, weekly), as "
                                  f"{STANDING}. Weight 10%."),
    "invite.track_record": ("How their NDN posts did",
                            f"How the artist's past NDN TikToks and YouTube sessions did compared with NDN's usual, "
                            f"as {STANDING}. New artists get 50. Weight 5%."),
    "invite.new_hit_hype": ("New song's Spotify plays",
                            f"Daily Spotify plays of the new song (kworb.net), as {STANDING}. Weight 15%."),
    "invite.momentum": ("Spotify PH chart", f"Best place on Spotify's Philippines weekly chart in the last 8 weeks, "
                                            f"as {STANDING}. Weight 10%."),
    "invite.local_reach": ("Listeners in Manila + Baguio",
                           f"Spotify listeners in Metro Manila and Baguio (half credit for the rest of the Philippines), "
                           f"from the artist's top 5 cities, as {STANDING}. Weight 5%."),
    "invite.fan_demand": ("Fan requests", f"Fans asking for the artist in NDN comments per 1,000 comments, as "
                                          f"{STANDING}. Weight 10%."),
    "invite.size": ("Artist size", f"Spotify monthly listeners, as {STANDING}. Weight 5%."),
    "invite.new_hit": ("New song to film", "The artist's song that came out after their last NDN visit and isn't on "
                                           "NDN's YouTube yet; if several, the one with the most TikTok videos."),
    "invite.new_hit_found_on": ("Found on", "Where the new song's buzz shows: TikTok, Spotify or both."),
    "invite.new_hit_tiktok_videos": ("TikTok videos using it", "Videos on TikTok using the new song's official sound "
                                                               "(sound page, latest weekly count)."),
    "invite.new_hit_tiktok_growth_4w": ("Change in 4 weeks", "Change in that number of TikTok videos over 4 weeks; "
                                                             "+50% = half as many again."),
    "invite.new_hit_daily_streams": ("Spotify plays per day", "Daily Spotify plays of the new song (kworb.net, latest)."),
    "invite.new_hit_released": ("Out since", "Release date (Deezer; if missing, the date the TikTok sound appeared)."),
    "invite.top_song": ("Top Spotify song", "The artist's most-played song on Spotify right now."),
    "invite.top_song_daily_streams": ("Spotify plays per day", "Daily Spotify plays of that top song (kworb.net)."),
    "invite.top_song_on_ndn": ("Top song on NDN", "yes = NDN already has that song on YouTube."),
    "invite.top_tiktok_song": ("Top TikTok song", "The artist's song with the most TikTok videos using its sound."),
    "invite.top_tiktok_song_videos": ("TikTok videos using it", "Videos on TikTok using that song's sound (weekly)."),
    "invite.monthly_listeners": ("Spotify monthly listeners", "People who played the artist on Spotify in the last "
                                                              "28 days (Spotify artist page, weekly)."),
    "invite.spotify_followers": ("Spotify followers", "People following the artist on Spotify (weekly)."),
    "invite.followers_per_listener": ("Followers per listener", "Spotify followers ÷ monthly listeners: how many "
                                                                "listeners became fans. Shown, not scored."),
    "invite.ph_listeners": ("Listeners in PH top cities", "Spotify listeners in the artist's top 5 cities that are "
                                                          "in the Philippines."),
    "invite.manila_baguio_listeners": ("Listeners in Manila + Baguio", "Of those top 5 cities, listeners in Metro "
                                                                       "Manila or Baguio."),
    "invite.best_chart_rank": ("Best spot on the Spotify PH chart", "Best place on Spotify's Philippines weekly top "
                                                                     "200 in the last 8 weeks (1 = top). Empty = not on it."),
    "invite.weeks_on_chart": ("Weeks on the chart", "Weeks on Spotify's Philippines weekly top 200 in the last 8 weeks."),
    "invite.tiktok_handle": ("Artist's TikTok", "The artist's TikTok account: listed by Vic, tagged in NDN captions, "
                                                "or matched from their Instagram name and checked."),
    "invite.tiktok_found_by": ("How the TikTok was found", "Vic's list, an NDN caption tag, or the Instagram name match."),
    "invite.tiktok_followers": ("TikTok followers", "Followers on the artist's TikTok (public profile, weekly)."),
    "invite.tiktok_follower_growth_4w": ("TikTok follower change, 4 weeks", "Change in those followers over 4 weeks."),
    "invite.fans_asking": ("Fans asking NDN", "Different people asking NDN for this artist in YouTube + TikTok "
                                              "comments, last 12 months."),
    "invite.tiktok_asks": ("TikTok asks", "Comments on NDN's TikTok asking for this artist."),
    "invite.ndn_youtube_videos": ("NDN YouTube videos", "NDN YouTube videos featuring the artist."),
    "invite.ndn_tiktok_clips": ("NDN TikTok clips", "NDN TikToks featuring the artist."),
    "invite.ndn_tiktok_index": ("Their NDN TikToks compared with usual", "The artist's middle NDN TikTok: views ÷ the "
                                                                          "usual of the posts around it. 1.0 = usual."),
    "invite.ndn_youtube_index": ("Their NDN YouTube compared with series", "The artist's middle NDN YouTube video "
                                                                            "compared with its series. 1.0 = usual."),
    "invite.latest_visit": ("Latest NDN visit", "Start of the artist's latest NDN filming visit, judged from post dates."),
    "invite.last_ndn_post": ("Last NDN post", "Latest NDN post featuring the artist."),
    "invite.cooldown_until": ("Invite after", "10 months after the latest NDN visit."),

    # invite_top30: the OPM top 30 of three Spotify playlists, with TikTok videos (sql/029), one row per song
    "invite_top30.rank": ("#", "Place in the OPM top 30 by list points (1 = most)."),
    "invite_top30.song": ("Song", "OPM song on Spotify's Top 50 - Philippines, Viral Hits Philippines or the Billboard "
                                  "Philippines Hot 100 playlist (weekly)."),
    "invite_top30.artist": ("Artist", "Main artist on Spotify. OPM = 90%+ of their top-city listeners are in the "
                                      "Philippines, or an NDN / Vic's-list artist."),
    "invite_top30.points": ("List points", "Top 50 PH #1 = 100 ... #50 = 2; Viral Hits PH and Billboard PH Hot 100 "
                                           "#1 = 100 ... #100 = 1; added up over the three lists (most = 300)."),
    "invite_top30.top50_pos": ("Top 50 PH", "Place on Spotify's Top 50 - Philippines (daily chart playlist). Empty = not on it."),
    "invite_top30.viral_pos": ("Viral Hits PH", "Place on Spotify's Viral Hits Philippines playlist. Empty = not on it."),
    "invite_top30.billboard_pos": ("Billboard PH Hot 100", "Place on the Billboard Philippines Hot 100 (a fan-made "
                                                           "Spotify copy, updated weekly). Empty = not on it."),
    "invite_top30.tiktok_videos": ("TikTok videos so far", "All TikTok videos using the song's counted sounds: its "
                                                           "official sound plus versions found by searching the title on "
                                                           "TikTok (every 3 days)."),
    "invite_top30.videos_added_7d": ("TikTok videos added in 7 days", "New TikTok videos in about a week over those "
                                                                      "sounds. Empty until two counts 5+ days apart."),
    "invite_top30.growth_4w": ("Change in 4 weeks", "Growth of those TikTok videos over 4 weeks; +50% = half as many again. "
                                                    "Empty until a count 6+ days earlier exists."),
    "invite_top30.sounds_kept": ("Sounds counted", "TikTok sounds counted for the song: credited to the artist, or 2+ "
                                                   "captions on the sound's page name the artist."),
    "invite_top30.fan_sounds_kept": ("Fan uploads counted", "Of those, fan uploads (sped up, covers, 'original sound') "
                                                            "that passed the caption check."),
    "invite_top30.sounds_unchecked": ("Sounds waiting for the check", "Sounds found for the song whose captions are "
                                                                      "not checked yet."),
    "invite_top30.top_sound": ("Biggest sound", "The counted sound with the most videos (title / who uploaded it)."),
    "invite_top30.top_sound_link": ("Open it", "The biggest sound's TikTok page."),
    "invite_top30.to_do": ("To do", "What is still missing for the song's TikTok numbers."),
    "invite_top30.counted_on": ("Counted on", "Date of the latest TikTok count for the song's sounds."),
    "invite_top30.on_ndn": ("On NDN", "yes = NDN already has this song on YouTube."),
    "invite_top30.invite_group": ("Group", "Who to invite (the artist never played for NDN) or Post or boost (NDN has "
                                           "the song or the band)."),

    # YouTube extras
    "yt_heatmap.video_id": ("Post ID", "YouTube's own ID for the video."),
    "yt_heatmap.title": ("Session", "Title of the NDN YouTube session."),
    "yt_heatmap.artist": ("Artist", "Artist in the session."),
    "yt_heatmap.duration_sec": ("Length (seconds)", "Video length from YouTube."),
    "yt_heatmap.peak_sec": ("Most replayed moment (seconds)", "Where YouTube's public 'most replayed' graph peaks, "
                                                              "seconds into the video (read every Monday)."),
    "yt_heatmap.peak_pct": ("Most replayed moment (% in)", "That moment as a share of the video length."),
    "yt_heatmap.peak_band": ("Where the peak is", "Position of the most replayed moment in steps of 10% of the video. "
                                                  "00-10% = the opening."),
    "yt_heatmap.peak_ratio": ("Peak strength", "Peak height ÷ the graph's usual level. 2.0 = replayed twice as much "
                                               "as a usual moment."),
    "yt_search.query": ("Search", "Song + artist typed into YouTube search, as a fan would (90 searches every Monday)."),
    "yt_search.reason": ("Why searched", "newest = a recent NDN session; top_week = one of the week's most-watched sessions."),
    "yt_search.target_rank": ("This session's place", "Where this exact NDN session shows in the results (1 = top). "
                                                       "Empty = not found."),
    "yt_search.ndn_best_rank": ("NDN's place in results", "Best place of any NDN video in the results (1 = top). "
                                                          "Empty = no NDN video found."),
    "yt_search.first_channel": ("Ranked first", "Channel of the first result."),
    "yt_search.rank_band": ("NDN's place", "Grouped: first, top 3, 4-10, below 10 or missing."),
    "yt_trending.rank": ("#", "Place on YouTube's Philippines trending music list, latest day (read 9:10 am PH)."),
    "yt_trending.title": ("Trending video", "Video title, cut to 90 characters."),
    "yt_trending.channel_title": ("Channel", "Channel that posted it."),
    "yt_trending.views": ("Views", "Views when the list was read."),
    "yt_trending.is_ndn": ("NDN?", "yes = an NDN video."),
    "song_compare.song": ("Song", "Song filmed by NDN, matched across platforms by its name."),
    "song_compare.artist": ("Artist", "Artist of the song."),
    "song_compare.youtube_views": ("YouTube views", f"Views of NDN's YouTube video(s) of the song, latest {DAILY}."),
    "song_compare.tiktok_views": ("TikTok views", f"Views of NDN's TikToks of the song, latest {DAILY}."),
    "song_compare.instagram_likes": ("Instagram likes", f"Likes on NDN's Instagram posts of the song, latest {DAILY}."),

    # benchmarks (sql/021)
    "dim_account.account": ("Account", "Live-session channel compared with NDN."),
    "dim_account.region": ("Region", "ndn, domestic (Philippines), asia or international."),
    "bench_accounts.account_key": (None, "Short code for the account."),
    "bench_accounts.account": ("Account", "Live-session channel compared with NDN."),
    "bench_accounts.region": ("Region", "ndn, domestic (Philippines), asia or international."),
    "bench_accounts.platform": ("Platform", "TikTok, YouTube or Instagram."),
    "bench_accounts.followers": ("Followers", "Latest public follower count, read daily at 9:20 am PH."),
    "bench_accounts.total_views": ("Total views", "All views on the account, latest daily count."),
    "bench_accounts.total_likes": ("Total likes", "All likes on the account, latest daily count."),
    "bench_accounts.posts": ("Posts", "Posts on the account, latest daily count."),
    "bench_uploads.account": ("Account", "Live-session channel compared with NDN."),
    "bench_uploads.region": ("Region", "ndn, domestic (Philippines), asia or international."),
    "bench_uploads.platform": ("Platform", "TikTok, YouTube or Instagram."),
    "bench_uploads.uploads_12m": ("Uploads in 12 months", "Posts in the last 12 months, not counting the last 14 days."),
    "bench_uploads.uploads_per_month": ("Uploads per month", "Uploads in 12 months ÷ 12."),
    "bench_uploads.median_views": ("Usual views per upload", "Middle views of those uploads today: half got more, "
                                                             "half fewer. Posts under 14 days old are left out so "
                                                             "fresh uploads don't drag it down."),
}

HELPER = "Works behind the scenes (ranking or colour); not shown as a number."

MEASURES = {
    # Overview
    "Follower Growth %": ("Follower growth", "Followers each day ÷ followers on the first real day in the chosen "
                                             "dates, minus 1. A % so small and big channels fit one chart."),
    "Total Followers Text": (None, "TikTok + YouTube + Instagram followers at the latest daily count."),
    "As Of Text": (None, "Day of the latest real daily count."),
    "Insights Note": (None, "When and how the sentences below were written."),
    "Best Post Gained": ("Gained", "Views (likes on Instagram) the best post gained over about the last week."),
    # TikTok
    "TikTok videos": ("TikTok videos", "NDN TikToks left after the page filters."),
    "Median views per TikTok": ("Usual views per TikTok", "Middle views: half the videos got more, half fewer. "
                                                          f"From the {DAILY}."),
    "Median Index": ("Views compared with usual", "The middle video in the group: its views ÷ the usual views of the "
                                                  "30 NDN TikToks posted around it. 1.0 = usual, above 1 = better. "
                                                  "Comparing with nearby posts keeps old and new videos fair."),
    "Breakouts, all time": ("Breakout videos, all time", "Share of NDN TikToks with at least twice the usual views "
                                                         "of the 30 posts around them."),
    "Breakouts, last 30 days": ("Breakout videos, last 30 days", "The same share, TikToks posted in the last 30 days."),
    "TikTok Views 30d": ("Views", f"Views so far, TikToks posted in the last 30 days ({DAILY})."),
    "TikTok Index 30d": ("Views compared with usual", "Views ÷ the usual views of the 30 NDN TikToks posted around it. "
                                                      "2.0 or more = breakout."),
    "Breakout share": ("Share that broke out", "Share of the month's TikToks with at least twice the usual views of "
                                               "the posts around them."),
    "Median shares+saves per 1k": ("Shares + saves per 1,000 views", "The middle video: (shares + saves) ÷ views × "
                                                                     "1,000. TikTok reads both as strong signs people "
                                                                     "value a video."),
    "Median comments per 1k": ("Comments per 1,000 views", "The middle video: comments ÷ views × 1,000."),
    "Median 7-day views gained": ("Views gained, last 7 days", "The middle video: views added over the last 7 daily counts."),
    "Median 7-day gain per 1k, older posts": ("Views gained last week per 1,000 so far",
                                              "Videos older than 30 days, the middle one: views gained in the last 7 "
                                              "days ÷ views so far × 1,000. Higher = still being found."),
    "Videos made with NDN sounds": ("Videos made with NDN sounds", "Videos by anyone on TikTok that use the sound of "
                                                                   "an NDN post (sound pages, latest weekly count)."),
    "Shares+saves per 1k": ("Shares + saves per 1,000 views", "(Shares + saves) ÷ views × 1,000 for this TikTok."),
    "Sound uses": ("Videos using its sound", "Videos by anyone on TikTok made with this post's NDN sound (latest "
                                             "weekly count)."),
    "TikTok Artist Index Top 10": ("Views compared with usual", "Top 10 artists with 3 or more NDN TikToks: their "
                                                                "middle clip's views ÷ the usual. 1.0 = usual."),
    # YouTube
    "YouTube videos": ("YouTube videos", "NDN YouTube videos left after the page filters."),
    "YouTube Median Views/Day": ("Usual views per day", "Middle value of views so far ÷ days online: half the videos "
                                                        "do better, half worse."),
    "Median views/day, full sessions": ("Usual views per day, full sessions", "Full-length sessions only: middle value "
                                                                              "of views so far ÷ days online."),
    "Median views/day, Shorts": ("Usual views per day, Shorts", "YouTube Shorts only: middle value of views so far "
                                                                "÷ days online."),
    "YouTube views gained, last 7 days": ("Views gained, last week", "All NDN YouTube videos added up over about the "
                                                                     "last week of daily counts."),
    "YouTube Views Gained Real": ("Views gained that day", "All NDN YouTube videos added up, real daily counts only."),
    "YouTube Views/Day 90d": ("Views per day", "Views so far ÷ days online, videos uploaded in the last 90 days."),
    "YouTube vs Series 90d": ("Compared with its series", "Views per day ÷ the middle video of the same series. "
                                                          "2.0 = twice as good as usual for the series."),
    "YouTube Artist Views/Day": ("Views per day", "Views per day added up over the artist's NDN YouTube videos."),
    "YouTube Artist Views/Day Top 10": ("Views per day", "Top 10 artists: views per day added up over their NDN "
                                                         "YouTube videos."),
    "YouTube engagement rate": ("Likes + comments per view", "The middle video: (likes + comments) ÷ views. "
                                                             "3% = 3 likes or comments per 100 views."),
    "YouTube median 7-day gain": ("Views gained, last 7 days", "The middle video: views added over the last 7 daily counts."),
    "YouTube 7-day gain, older sessions": ("Views gained, last 7 days", "Sessions over a year old: views added over "
                                                                        "the last 7 daily counts."),
    "YouTube views per day": ("Views per day", "Full sessions: views so far ÷ days online."),
    "YouTube artist listeners": ("Artist's Spotify monthly listeners", "People who played the artist on Spotify in "
                                                                       "the last 28 days (Spotify artist page, weekly)."),
    "YouTube song Spotify streams": ("Song's Spotify plays", "All-time Spotify plays of the studio version of the "
                                                             "song (kworb.net, weekly)."),
    "Sessions": ("Sessions", "NDN YouTube sessions that have a public 'most replayed' graph (read every Monday)."),
    "Searches": ("Searches", "YouTube searches for a song NDN filmed (90 every Monday)."),
    # Instagram
    "Instagram posts": ("Instagram posts", "NDN Instagram posts left after the page filters."),
    "Median likes/day, all posts": ("Usual likes per day", "Middle value of likes so far ÷ days online: half the "
                                                           "posts do better, half worse."),
    "Median views/day, Reels": ("Usual views per day, Reels", "Reels only: middle value of views so far ÷ days "
                                                              "online. Instagram's view count includes Facebook "
                                                              "views since April 2026."),
    "Instagram likes gained, last 6 days": ("Likes gained, last 6 days", "All NDN Instagram posts added up. Real "
                                                                         "daily counts started 15 Oct 2026."),
    "Instagram Likes Gained Real": ("Likes gained that day", "All NDN Instagram posts added up, real daily counts only."),
    "Instagram Likes/Day 90d": ("Likes per day", "Likes so far ÷ days online, posts of the last 90 days."),
    "Instagram Views/Day 90d": ("Views per day", "Reels of the last 90 days: views so far ÷ days online."),
    "Reel views per day": ("Views per day", "Reels: views so far ÷ days online."),
    "Reel artist listeners": ("Artist's Spotify monthly listeners", "People who played the artist on Spotify in the "
                                                                    "last 28 days (Spotify artist page, weekly)."),
    "Median reposts per 1k views": ("Reposts per 1,000 views", "The middle post: reposts ÷ views × 1,000. Shares "
                                                               "and saves are private on Instagram."),
    "Median comments per 1k likes": ("Comments per 1,000 likes", "The middle post: comments ÷ likes × 1,000."),
    "Instagram median 7-day likes gained": ("Likes gained, last 7 days", "The middle post: likes added over the "
                                                                         "last 7 daily counts."),
    "Song YouTube views": ("YouTube views", f"Views of NDN's YouTube video(s) of the song, latest {DAILY}."),
    "Song Instagram likes": ("Instagram likes", f"Likes on NDN's Instagram posts of the song, latest {DAILY}."),
    # Benchmarks
    "Is NDN Account": (None, HELPER),
    "Is NDN Uploads": (None, HELPER),
    # Community
    "Artists fans ask for": ("Artists fans ask for", "Artists named in NDN's YouTube + TikTok comments asking NDN to "
                                                     "feature them, last 12 months."),
    "Never on NDN": ("Asked for, never on NDN", "Of those, artists NDN hasn't filmed yet."),
    "Artists with upload requests": ("Artists with upload requests", "Artists whose filmed session fans ask NDN to "
                                                                     "post or put on streaming."),
    "Fans Asking": ("Fans asking", "Different people asking for the artist, last 12 months. One person asking 5 "
                                   "times counts once."),
    "Fans Asking Top 15": ("Fans asking", "Top 15 artists by different people asking, last 12 months."),
    "Is Never Played": (None, HELPER),
    # Invite
    "Artists scored": ("Artists checked", "Artists the invite score was worked out for: NDN artists, Vic's list and "
                                          "OPM artists from Spotify's PH chart and Viral Hits PH."),
    "To invite": ("To invite", "Artists of the OPM top 30 who never played for NDN: invite them."),
    "To post or boost": ("To post or boost", "Artists of the OPM top 30 NDN already has: their hot song is on NDN's "
                                             "YouTube (boost it), or they played for NDN before (post their clips)."),
    "Hot songs NDN has": ("Hot songs NDN has", "Songs in the OPM top 30 that are already on NDN's YouTube."),
}

for _p in PLATFORMS:
    MEASURES[f"{_p} Followers Text"] = (None, f"{_p} followers at the latest {DAILY}."
                                        + (" YouTube rounds subscribers to 3 digits." if _p == "YouTube" else ""))
    MEASURES[f"{_p} Change Text"] = (None, "Follower change over about the last week. YouTube rounds subscribers, "
                                           "so small changes can show as none.")
    MEASURES[f"{_p} Gained Text"] = (None, "Views (likes on Instagram) all posts gained over the same days, and the "
                                           "number of new posts.")
    MEASURES[f"Followers {_p}"] = ("Followers", f"Latest public {_p} follower count, read daily at 9:20 am PH.")
    MEASURES[f"Median Views {_p}"] = ("Usual views per upload", "Middle views of the uploads of the last 12 months "
                                                                "(not the last 14 days): half got more, half fewer.")
    MEASURES[f"Uploads/Month {_p}"] = ("Uploads per month", "Uploads in the last 12 months ÷ 12.")
for _label in ["Headline", "Action 1", "Action 2", "Action 3", "Audience", "Sessions", "Uploads"]:
    MEASURES[f"Insight {_label}"] = (None, "Written at 3 pm PH by a Claude routine from that day's numbers only.")
for _pre in ["Inv", "Pob"]:
    MEASURES[f"{_pre} Score Raw"] = (None, HELPER)
    MEASURES[f"{_pre} Rank Raw"] = (None, HELPER)
    MEASURES[f"{_pre} Rank"] = ("#", "Place by invite score among the artists the page filters leave (1 = best).")


def invite_measure(name: str):
    """'Inv new_hit' -> the label and help of invite.new_hit (the invite tables show columns through measures)."""
    pre, _, column = name.partition(" ")
    if pre in ("Inv", "Pob") and f"invite.{column}" in COLUMNS:
        return COLUMNS[f"invite.{column}"]
    return None


def lookup(key: str):
    """(plain name, help) for 'table.column' or a measure name, or None."""
    return COLUMNS.get(key) or MEASURES.get(key) or invite_measure(key)
