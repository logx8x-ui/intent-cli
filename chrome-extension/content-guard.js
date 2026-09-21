let intentRules = {
  active: false,
  accessMode: "whitelist",
  allowedWebsites: [],
  blockNavigation: false,
  allowGoogleSearchTabs: false
};

function updateRules(nextRules) {
  intentRules = nextRules || intentRules;
}

try {
  chrome.runtime.sendMessage({ type: "getActiveRules" }, (response) => {
    if (!chrome.runtime.lastError) updateRules(response);
  });
} catch (_) { /* An extension reload can invalidate an old content-script context. */ }
chrome.runtime.onMessage.addListener((message) => {
  if (message?.type === "rulesUpdated") updateRules(message.rules);
});

function blockUnallowedLink(event) {
  if (!intentRules.active || !intentRules.blockNavigation || Array.isArray(intentRules.selectedTabIDs)) return;
  const link = event.target?.closest?.("a[href]");
  if (!link || IntentBrowserRules.isAllowedURL(link.href, intentRules)) return;
  event.preventDefault();
  event.stopImmediatePropagation();
}

document.addEventListener("click", blockUnallowedLink, true);
document.addEventListener("auxclick", blockUnallowedLink, true);
