# Browser field of view follow-up

## Behavior

- Tab bubbles use the browser-provided favicon URL and a shortened page title. Selection adds a green outline and a small check without replacing the site's icon.
- Clicking a browser window emphasizes its tab strip and explains individual selection; it never changes the selected-tab set. Clicking a tab remains the sole selection action.
- Hovering for one second requests a rendered viewport preview. Moving away cancels the UI request. The preview contains the full tab title and host, and never intercepts clicks.
- Chrome captures the requested tab behind the picker without focusing the browser window, then restores the previous active tab. Firefox uses captureTab. Restricted, private, discarded, and failed captures show an explicit unavailable message rather than an unrelated image.
- Preview screenshots use the existing local native bridge. The app consumes and deletes the temporary response; the host also schedules expiration of an unconsumed response after ten seconds. No screenshot upload or continuous capture is added. Favicons load from the URL supplied by the browser, not a third-party favicon lookup service.

## Restriction repair

An activation that arrives while returnToAllowedTab is already enforcing used to return early and disappear. The guard now queues another enforcement pass. A low-frequency check on the existing heartbeat also repairs missed activation events in the last-focused browser window; no new idle timer is added. Selected-tab sessions refuse a disabled guard and stop with an explanation if its heartbeat/capability disappears or it is switched off.

The initial installed two-tab reproduction correctly rejected a third YouTube tab, so it did not reproduce Logan's exact live incident. A deterministic interrupted-return regression does reproduce the dropped-event failure: removing the queue fix in memory makes the test fail; the patched implementation passes.

## Automated evidence

- Chrome tests cover two selected YouTube videos, rejection of a third same-site tab, returning to the last allowed tab, new tabs, other windows, concurrent activations, interrupted returns, and missed-event recovery.
- Preview tests cover request identity, capture, restoration without focusing Chrome, and favicon metadata.
- Chrome/Firefox rule and background tests and browser idle-work regression checks pass.
- Chrome and Firefox extension archives build; Firefox lint reports zero errors, warnings, and notices.
- IntentCoreSpec and debug IntentApp build pass.

## Platform boundary

Previews are visible-page snapshots, not stitched full-length scrolling screenshots. Chrome's supported API captures the active tab in a specified window; it does not offer Firefox's direct background-tab capture API. Sources: [Chrome tabs API](https://developer.chrome.com/docs/extensions/reference/api/tabs), [Firefox captureTab](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabs/captureTab).

Firefox on this Mac previously had Browser Guard 0.2.5 loaded. Source compatibility does not establish installed Firefox acceptance; record the live outcome separately below.

## Installed verification

- Production app, CLI, and native host builds passed; data-preserving development installation completed. Installed app passed strict signature verification.
- Chrome Browser Guard 0.2.7 was reloaded from this checkout. Its heartbeat advertises the matching selected-tab and preview capabilities.
- Visually confirmed real red YouTube logos and truncated video titles, with the icon retained inside a green selected bubble.
- Clicking the browser window left Apps 0 / Tabs 0 and emphasized individual tab selection.
- Coordinate-clicked and lingered on a YouTube bubble: the delayed popup showed the actual rendered lesson page, full title, and host. After capture, the browser snapshot confirmed its previously active Extensions tab had been restored.
- Selected two YouTube tabs and started with Cmd+G. Both were usable. Clicking a third same-site tab returned to the second selected tab. Repeated Cmd+3 / Cmd+5 / Cmd+3 attempts also left the second selected tab active; native rules still contained exactly the two selected IDs.
- Finish presented Save. Discarded only the temporary test candidate and left browser rules inactive.
- Native-host metadata/preview protocol and performance tests passed (peak RSS 7.8 MiB in the performance harness).
- Firefox still reports loaded Browser Guard 0.2.5 with no selected-tab capability. Firefox source/rule/background tests pass, but the new Firefox UI/preview/enforcement behavior is not live-accepted on this Mac. No Firefox signing or privacy settings were bypassed.

The guard-disabled/disconnect session-stop branch is code-checked, not a separate live forced-disconnect acceptance test. Multi-monitor and cross-Space capture coverage remains outside this follow-up.
