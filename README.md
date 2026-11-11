# Notification drawer for Omarchy

A bell on the bar. Click it and a drawer opens on the right with today's notifications. Toasts still appear and then leave on their own; they do not open the drawer.

- **Grouped** piles copies that share an app and a title. Click a pile to see each copy. The control sits beside the title.
- **Close all** clears the drawer. Each row has its own close. **Quiet** silences new toasts.
- Opening a row marks that one read and runs its action, or focuses the app.

## Install

```bash
omarchy plugin add https://github.com/riopierrefrancois/omarchy-notifications.git --enable
```

It goes on the right side of the bar. Omarchy's own notification service still shows the toasts.

## Files

- `manifest.json` — the plugin manifest (id `pfr.notifications`).
- `Panel.qml` — the bell and the drawer.
- `History.js` — reading, grouping, and which rows are closed.
- `history.test.mjs` — `node history.test.mjs`.
- `i18n/en.json` — English strings.
