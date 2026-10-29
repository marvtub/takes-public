// Right-click on selected words: "Record in Takes".
import { takesLink } from "./takes.js";

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({ id: "record", title: "Record in Takes", contexts: ["selection"] });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId !== "record" || !info.selectionText || !tab?.id) return;
  // The browser asks once to open Takes; the page stays where it is.
  chrome.tabs.update(tab.id, { url: takesLink(info.selectionText, tab.title) });
});
