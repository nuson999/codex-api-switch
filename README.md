# Codex API Switch

Store several OpenAI-compatible API endpoints (base URL + key) and switch the ChatGPT/Codex desktop app on Windows between them and your normal ChatGPT login. When you switch to an API, the app's model picker shows that API's models. When you switch back, your original config is restored exactly.

Works for the Codex desktop app, the Codex CLI and the IDE extension, since all three read `%USERPROFILE%\.codex\config.toml`.

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1 (built in)
- The ChatGPT/Codex desktop app or Codex CLI
- An API endpoint that supports the **Responses API** (`POST /v1/responses`). Endpoints that only offer `/chat/completions` won't work with Codex.

## Install

Download or clone this repository into any folder. You don't need to install anything else.

```bash
git clone https://github.com/nuson999/codex-api-switch.git
```

## Use it

Double-click **`Codex API Switch.cmd`**.

| Button | What it does |
|---|---|
| Use selected API (or double-click a row) | Points Codex at that endpoint |
| Back to ChatGPT | Restores your original settings exactly |
| Add API... / Edit... | Name, base URL, key, model. **Fetch list** pulls the model ids from the endpoint |
| Remove | Deletes one API and its key |
| Test | Checks `/models` and `/responses` (Codex needs `/responses`) |
| Refresh models | Re-fetches the active API's model list into the app's model picker. This also runs automatically each time the window opens |
| Remove everything... | Back to ChatGPT, then deletes all saved APIs, keys and backups |

Leave **Restart app on switch** ticked. Codex reads its config only when it starts.

## Command line

```bash
codex-switch.cmd add mygateway -BaseUrl https://api.example.com/v1 -Model your-model-id
codex-switch.cmd use mygateway -Restart
codex-switch.cmd off -Restart
codex-switch.cmd list
codex-switch.cmd status
codex-switch.cmd test mygateway
codex-switch.cmd models mygateway
codex-switch.cmd refresh -Restart
codex-switch.cmd remove mygateway
codex-switch.cmd purge
```

Run it with no arguments to get a text menu. If you leave out `-Key`, `add` asks for the key in a hidden prompt, which keeps it out of your shell history.

## What it changes

- **Profiles:** `%USERPROFILE%\.codex\codex-switch\profiles.json`. Keys are encrypted with Windows DPAPI, so only your Windows account can read them. Nothing is stored in the folder you cloned.
- **`use`:** Edits `%USERPROFILE%\.codex\config.toml`. It sets `model_provider = "codexswitch"` and `model`, plus `model_reasoning_effort` if the profile has one. It comments out `service_tier` (the ChatGPT-only fast tier) and appends a `[model_providers.codexswitch]` block.
- **Model picker:** `use` also downloads the API's `/models` list and writes `codex-switch\model-catalog.json`. It then points `model_catalog_json` at that file, so the desktop picker shows exactly that API's models, with the profile's model first. Each entry is copied from Codex's own `models_cache.json`, so it fits your Codex version. `off` deletes the file and restores your original picker. Add `-NoCatalog` to `use` if you want to keep Codex's normal list.
- **The key:** While an API is active, its key goes into the user environment variable `CODEX_SWITCH_API_KEY`, unencrypted. If you use `-InlineKey`, it is written into `config.toml` instead. `off` removes it either way.
- **`off`:** Puts back the original lines in their original positions and deletes the env var. The file comes back byte-for-byte identical.
- **Not touched:** `auth.json` (your ChatGPT login) and every other setting.
- **Backups:** Taken before every write and kept in `codex-switch\backups` (newest 20).

## Troubleshooting

- **401 or "missing environment variable" in the app:** the app didn't receive the key. Run `codex-switch.cmd use <name> -InlineKey -Restart`.
- **The picker doesn't show the API's models:** fully quit the app (tray icon > Quit) and reopen it, or use `-Restart`.
- **400 errors:** the endpoint probably lacks `/v1/responses`. Run **Test**.

## Known limits

- Every API uses the same provider id (`codexswitch`). Chats stay visible when you switch from one API to another. Chats from ChatGPT mode may be grouped separately from API chats. That's how Codex Desktop works.
- The picker list only changes when the app restarts. If **Refresh models** finds changes, restart the app.
- The picker needs Codex's model cache, which comes from opening Codex once with your ChatGPT login. A copy is saved, so it keeps working later. Without it, the API still works, but the picker shows Codex's normal list.
- Windows only.

## Disclaimer

This is an unofficial tool and isn't affiliated with OpenAI. It edits your local Codex config, with backups. Use only API services you're allowed to use, and follow their terms.

## License

MIT
