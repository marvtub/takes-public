// The link that hands words to the Takes app: takes://new makes a session in Inbox with the
// words as its script (AppModel.handle in the app). Nothing leaves the Mac.
export const LIMIT = 20000;

export function takesLink(text, title) {
  // encodeURIComponent, not URLSearchParams: its "+" for a space stays a "+" in the app's URLComponents.
  const t = encodeURIComponent(text.trim().slice(0, LIMIT));
  return `takes://new?text=${t}&title=${encodeURIComponent((title || "").trim().slice(0, 80))}`;
}
