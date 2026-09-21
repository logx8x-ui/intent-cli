const checkbox = document.getElementById("enabled");
const statusText = document.getElementById("status");
function render(status) {
  checkbox.checked = status.enabled !== false;
  statusText.textContent = status.enabled === false ? "Guard off" :
    status.connected === true ? "Connected to Intent" : "Reconnecting to Intent…";
}
async function load() {
  try { render(await chrome.runtime.sendMessage({ type: "getGuardStatus" })); }
  catch (_) { statusText.textContent = "Connecting to Intent…"; }
}
checkbox.addEventListener("change", async () => {
  checkbox.disabled = true;
  try { render(await chrome.runtime.sendMessage({ type: "setGuardEnabled", enabled: checkbox.checked })); }
  catch (_) { statusText.textContent = "Could not update guard — retrying…"; }
  finally { checkbox.disabled = false; }
});
load();
// Only while the popup is open; the background connection retains its backoff.
setInterval(load, 1500);
