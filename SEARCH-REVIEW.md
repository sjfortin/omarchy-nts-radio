# Archive search review

Local branch: `improve-archive-search`. No version bump or release.

Search now fetches shows, episodes, tracks and tags independently. Episodes
and artist/track matches start with 24 results, with per-category counts and
Load more controls. Filters let you browse one category without scrolling
past the others. Repeated rows are deduplicated and failed pages can be retried
without losing earlier results.

Artist/track matches link to the episode containing the track. Play episode
fetches the episode's audio metadata, then plays or resumes the full episode;
Save also fetches metadata so the saved episode retains its audio source. It does not play isolated tracks or jump to a track
timestamp. Availability still depends on the episode's NTS audio source.

Genre suggestions offer common spellings (for example, Rege → Reggae) without
changing the original query. These suggestions use a small local list, not a
complete genre taxonomy or general artist spellchecker. Tags remain text
searches, not strict genre filters. NTS controls relevance and result totals;
counts across categories are matches, not unique playable episodes. Pagination
retains the API wrapper's existing maximum offset of 5,000.

## Try locally

Omarchy may retain cached QML components after a plugin hot reload. If the
category tabs are missing or only six episodes appear, restart the shell once
(`omarchy restart shell`), then reopen search. This briefly interrupts playback.

```sh
omarchy-shell nts-radio open search
```

- Search `Desmond Decker` or `Desmond Dekker`; choose **Artist / track**.
- Scroll to **Load more tracks** and check that older matches append.
- Use **Play episode**, **Save**, or click a track row to open its episode.
- Search `Rege`, choose **Try Reggae**, then select **Episodes** and load more.
- Switch categories with Tab. Arrow keys select results; P plays and B saves.
  In a single category, Down on the last loaded row requests the next page.
- Change queries quickly or clear the input while loading; old results should
  never reappear. A failed category has its own Retry button.

## Checks

```sh
node tests/search.test.cjs
QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=basic QT_QUICK_BACKEND=software \
  /usr/lib/qt6/bin/qmltestrunner -input tests/qml -import tests/support
```

The QML suite uses mock API responses and lightweight shell style singletons.
It tests request races, retry offsets, keyboard filtering, input synchronization,
track playback metadata, and rendering. Its preview is saved to
`/tmp/nts-search-review.png`. Live API queries separately verified artist,
genre, and second-page responses. Actual audio output remains a manual review.

## Pre-merge review

Fixed during review:

- A pending track playback response could override a later episode selection.
  Episode playback now invalidates earlier track requests.
- Arriving results could clear or move the keyboard selection. It now stays
  on the same result when an earlier section grows.
- Saving a track match previously stored incomplete episode metadata. Saves
  now fetch the episode, preserve its audio URL, prevent duplicate requests,
  and allow retry after a failure.

Regression checks cover these cases and click the actual Load more control,
including its disabled loading state and disappearance after the last page.
