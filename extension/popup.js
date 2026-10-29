// The toolbar button: the page's selected words and title, ready to edit, then one click to Takes.
import { takesLink, LIMIT } from "./takes.js";

const text = document.getElementById("text");
const title = document.getElementById("title");
const go = document.getElementById("go");
const hint = document.getElementById("hint");

function update() {
  go.disabled = !text.value.trim();
  if (text.value.length > LIMIT) hint.textContent = `Only the first ${LIMIT.toLocaleString()} characters go to Takes.`;
}
text.addEventListener("input", update);

const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
title.value = (tab?.title || "").slice(0, 80);
try {
  const [res] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: () => String(getSelection()) });
  text.value = res?.result || "";
} catch {
  // Browser pages (settings, the store) allow no script: write the words here instead.
}
update();
text.focus();

go.addEventListener("click", async () => {
  await chrome.tabs.update(tab.id, { url: takesLink(text.value, title.value) });
  window.close();
});
