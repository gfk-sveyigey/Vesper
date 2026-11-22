# Emby intro / credits integration

API contracts checked on 2026-11-20:

- IntroDB: <https://api.introdb.app/openapi.json>
  - GET `/segments?imdb_id=...&season=...&episode=...`
  - Movies: `imdb_id=...&is_movie=true`.
  - `intro` and `outro` are nullable objects with `start_ms` / `end_ms`.
- TheIntroDB: <https://api.theintrodb.org>
  - GET `/v4/media`, preferring `tvdb_id`, then `tmdb_id`, then `imdb_id`.
  - Episodes include `season` and `episode`; `duration_ms` chooses a release cluster.
  - `intro` and `credits` are arrays. Intro start can be null (= zero), credits end can be null.

Episode lookup uses the **parent series** provider IDs, never an episode IMDb/TMDB ID as a series ID.
Queries use a separate ephemeral URLSession without Emby authentication headers. Custom endpoints must
use HTTPS. No manual marker editing or submission endpoints are exposed.

Enabled databases are queried in configured order. Stop at the first response with a valid intro or
credits marker; do not mix markers from different databases. Invalid, missing, failed or empty results
fall through. Results and misses are cached for ten minutes, bounded to 100 query keys, and identical
in-flight requests are shared between detail screens and playback.

Intro intervals are validated against the selected version's duration and overlaps merged. Automatic
intro seeks are once per interval per playback generation, while playing, not loading/scrubbing.
Credits advance only when an episode has another episode in its current queue; the last episode and
standalone movies are left playing. Failure of marker lookup never blocks playback.

Body-duration preloading uses `(duration - introDuration - creditsDuration) * fraction + introDuration`.
Disabled or missing intro/credits markers contribute zero. When lookup is in flight, body-duration
preloading waits for the result rather than speculating at a different position.

## Device / CI verification still required

- Enable/disable intro and credits independently; missing markers must not cause a seek.
- Reorder providers; first valid result wins. Disable a provider; it must issue no requests.
- Built-ins cannot be edited/deleted. Add/edit/remove a custom provider for each format.
- Exercise movie, episode and series detail (including selected episode/version changes).
- Seek backward into an already skipped intro: no forced repeat skip. Pause/scrub: no automatic skip.
- Credits with no next episode: do not stop or jump to an unrelated history entry.
- For 600s total, a 60s intro, 50s credits and 80% fraction, preload at 452s; both disabled: 480s.
- Check source changes and rapid episode changes do not apply stale markers to the next item.
