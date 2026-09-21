const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
(async () => {
  for (const name of ['chrome', 'firefox']) {
    const elements = { enabled: { addEventListener() {} }, status: {} };
    let response = {enabled: true, connected: false};
    let fail = false;
    const api = {runtime: {sendMessage: async () => {
      if (fail) throw new Error('background unavailable');
      return response;
    }}};
    const context = {browser: api, chrome: api, document: {getElementById: id => elements[id]}, setInterval() {}};
    vm.runInNewContext(fs.readFileSync(`${name}-extension/popup.js`, 'utf8'), context);
    await context.load();
    assert.equal(elements.status.textContent, 'Reconnecting to Intent…');
    response = {enabled: true, connected: true};
    await context.load();
    assert.equal(elements.status.textContent, 'Connected to Intent');
    fail = true;
    await context.load();
    assert.equal(elements.status.textContent, 'Connecting to Intent…', 'failed status request must clear prior success');
    fail = false;
    response = {enabled: false, connected: true};
    await context.load();
    assert.equal(elements.status.textContent, 'Guard off');
  }
  console.log('Browser popup connection status spec passed');
})().catch(error => {console.error(error); process.exitCode = 1;});
