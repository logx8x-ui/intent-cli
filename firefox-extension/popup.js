const checkbox = document.getElementById("enabled");
const statusText = document.getElementById("status");

function render(enabled) {
  checkbox.checked = enabled;
  statusText.textContent = enabled ? "Guard on" : "Guard off";
}

async function load() {
  try {
    const response = await browser.runtime.sendMessage({ type: "getGuardStatus" });
    render(response.enabled !== false);
  } catch (_) {
    render(true);
  }
}

checkbox.addEventListener("change", async () => {
  const enabled = checkbox.checked;
  render(enabled);
  try {
    await browser.runtime.sendMessage({ type: "setGuardEnabled", enabled });
  } catch (_) {
    statusText.textContent = "Could not update guard";
  }
});

load();
