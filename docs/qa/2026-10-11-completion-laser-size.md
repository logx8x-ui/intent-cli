# Slightly more noticeable completion laser

Reported sequence: finishing an intention already shows the existing coloured
screen-edge sweep. Logan wants it a little bigger and longer, while retaining
the current effect. The finish window, browser tab and Space must stay untouched.

Adjacent behaviour retained: whitelist/blacklist share the existing dark-mode
accent with the HUD; feedback never activates Intent, becomes key/main, captures
clicks or repeats. Reduce Motion still uses the static 1-point fade. Existing
occurrence cancellation, locked-session checks and nonactivating panel setup
are unchanged.

The source adjustment changes the core from 1 to 1.2 points and its tail from
180 to 210 screen points. The faint halo changes from 2.2/220 to 2.5/250 points;
the tip from 1.35/12 to 1.5/14 points. Travel changes from 0.76 to 0.86 seconds,
and the entire one-shot effect from 1.05 to 1.18 seconds. The same-colour meeting
point changes from 2.5 to 2.8 points. There is no white core or screen-wide flash.

`npm run qa:plan` was inspected before editing. Deterministic checks inspect the
actual finite Core Animation layers for exact dimensions, consistent physical
tail lengths across display sizes, monotonic bounded strokes, mode colour,
complete end-of-life fading and static Reduce Motion. Rendering samples now
include the longer travel and late fade.

This scoped edit has not run a build, installed an app, opened a QA window or
claimed physical/rendered/focus acceptance. The owning chat runs the regression
gate and any installed acceptance on the final combined source.
