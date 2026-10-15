# Two- and three-finger task navigation

Request: two or three fingers swiping left should open the previously added notes/task
workspace. The workspace remains development-only as previously requested;
this main chat's shared fixes apply to both channels. The reported double-backtick issue happens after entering Apple Mission Control
and returning to the app; its exact failing output is still being investigated.

Changed the existing overview-local contact recognizer to accept two or three
stable contacts. Left enters Tasks; right returns to choosing
apps. Updated visible help. Vertical movement, four or more fingers, replaced
contacts, cancellation, and repeat navigation within one contact sequence stay
rejected. No global trackpad setting changes or additional competing event
monitor were introduced. The launch workspace entry point remains disabled.

The gesture fixtures now exercise left/right with both two and three contacts and reject
one/four/five contacts. They also retain cancellation, vertical-scroll,
replacement, and one-moving-finger coverage. Physical two- and three-finger trackpad
delivery remains an installed acceptance check, distinct from reducer tests.

Baseline commit: `037af1b22706f96c86a87d049da06a02b53f8083`. Validation and
installation evidence will be added after execution. Do not describe the
unspecified double-backtick issue as fixed by changing this page gesture.

## Executed verification

All six required suites passed in `intent-change-gate-TCkbyy`: gate, session,
Swift, Firefox/Chrome extensions, native host, release/channel. Runtime source
fingerprint: `fd44804222232c0920d847a3d640f374e6ec969b3ba6f19704e2bab797a13590`.
The current observer completed 60 consecutive successful live public AX/CG
observations of Chrome's actual profile picker, preserving identity 7699.
Receipts are copied to `dist/qa-20261015-two-three-finger/`.

Both home apps installed from this source: Test Intent UUID
`B34F5893-A884-30DF-B472-B2C4DDC32F00`, launch Intent UUID
`A79B1450-34AE-3781-80DA-C9F0D3801DF2`. Installed Test Intent opens Tasks and
returns through Choose apps; both help labels specify two or three fingers.
No user task data was changed. Physical finger delivery and complete physical
DBT-to-Mission-Control click-return remain pending. `releaseReady` stays false.

The existing private website passed all 24 download tests including local
Worker/R2 behavior. Public root returns the waitlist; anonymous download page
and binary endpoint return 404. Chrome's public store still serves 0.2.14 while
this candidate needs 0.2.46, so no download catalog was falsely qualified.
