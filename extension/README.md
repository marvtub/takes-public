# Record in Takes (browser extension)

Select words on any page, then right-click › **Record in Takes** or click the toolbar button. Takes
opens them as a new session in Inbox, with the words as the script, ready for the teleprompter.

The extension only builds a `takes://new?text=…&title=…` link and opens it (`takes.js`). Nothing
leaves the Mac: no server, no account, no tracking. The app side is `AppModel.handle(url:)` and
`Library.addSession`: it adds a session and leaves a notice; it never changes the screen.

Works in Edge and Chrome (Manifest V3). Permissions: `contextMenus` (the right-click item),
`activeTab` + `scripting` (read the selection of the tab you clicked, only then).

## Try it

Edge: `edge://extensions` › Developer mode › Load unpacked › this folder.

## Pack for the store

```bash
cd extension && zip -r ../build.noindex/record-in-takes-$(jq -r .version manifest.json).zip . -x 'store/*' 'README.md' '.*'
```

`store/` holds the listing: `listing.md` (the text), `logo-300.png`, `screenshot-1280x800.png`.
