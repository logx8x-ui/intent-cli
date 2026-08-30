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

chrome.runtime.sendMessage({ type: "getActiveRules" }, updateRules).catch(() => {});
chrome.runtime.onMessage.addListener((message) => {
  if (message?.type === "rulesUpdated") updateRules(message.rules);
});

function blockUnallowedLink(event) {
  if (!intentRules.active || !intentRules.blockNavigation) return;
  const link = event.target?.closest?.("a[href]");
  if (!link || IntentBrowserRules.isAllowedURL(link.href, intentRules)) return;
  event.preventDefault();
  event.stopImmediatePropagation();
}

document.addEventListener("click", blockUnallowedLink, true);
document.addEventListener("auxclick", blockUnallowedLink, true);
