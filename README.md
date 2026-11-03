# DigUp Personal

An independent Mac fork of [DigUp](https://github.com/ARahim3/DigUp), adding image/audio search queries and a local MCP server. The original llama.cpp backend and embedding format are preserved.

## Use your existing index

Open **DigUp Personal.app**. On first launch it imports DigUp’s saved folders, exclusions, schedule, onboarding state, and custom model/index locations into its own preferences. Its bundle identifier is `dev.digup.personal`.

By default, it uses `~/Library/Application Support/DigUp/index.noindex/index.sqlite` and the adjacent `Models` directory. It checks compatibility and takes an online SQLite backup in `index.noindex/backups/before-personal/` before its first indexing write. Existing vectors are retained. An incompatible index is left unchanged.

While original DigUp is running, Personal searches the index without starting its own indexing helper. Quit original DigUp to let Personal resume ordinary incremental indexing. MCP always opens the index read-only and can run with either app closed.

Personal builds have upstream updates disabled.

## Search with an image or audio clip

Use the paperclip in either search window, drop one image/audio file into the window, or paste an image with Command-V. Remove the attachment to return to text search. Opening the larger window from the quick panel retains the attachment.

Audio is an example to search with. A recording over 30 seconds opens a clip selector with playback and start/length controls. Short recordings default to their whole duration. Silence, invalid ranges, unreadable files, and missing models produce an explanation. Attachments are temporary query inputs and are not added to the index.

Each query uses text, one image, or one audio clip. Code search continues to use text queries beginning with `code:`.

## Connect Codex

Put the app in its final location, then copy the command from **Settings → Integrations**. For an app in Applications:

```sh
codex mcp add digup -- '/Applications/DigUp Personal.app/Contents/Helpers/digup-mcp'
```

Restart Codex after adding the connection. The server uses local stdio, needs no port or account, and does not load the model until a search requires it. Search results and context sent to Codex are handled like its other tool results.

### Tools

- `digup_search_files`: supply exactly one of `text`, `image_path`, or `audio_path`. File paths are absolute. Audio over 30 seconds also requires `start_seconds` and `duration_seconds` (at most 30). Optional `kinds`, `limit` (1–100, default 20), and `offset` filter/page results. Returns paths, excerpts, scores, page/time locations, `result_id`, and pagination fields. Text searches can fall back to keyword search with an explicit warning when inference is unavailable.
- `digup_get_result_context`: supply a returned `result_id`. Returns indexed text and an available image/PDF-page/video-frame preview, after checking current folder access. Audio keeps its time reference; no transcript is invented.
- `digup_index_status`: returns index counts, configured folders, and model readiness without starting inference or indexing.

Examples:

```json
{"text":"notes about neural networks","limit":10}
{"image_path":"/absolute/path/example.png","kinds":["image","pdf","video"]}
{"audio_path":"/absolute/path/recording.m4a","start_seconds":45,"duration_seconds":15}
```

Explicit query attachments can live outside indexed folders. Search results and context obey Personal’s chosen folders and exclusions. The server has no file-editing or indexing tools.

## Build and check

Apple Silicon, macOS 14+, full Xcode, Python 3, git, and CMake are required.

```sh
./build.sh
./script/build_and_run.sh
```

The app is staged at `build.noindex/DigUp Personal.app`. The build downloads pinned llama.cpp and SQLite sources, verifies them, and builds native app/helper/MCP executables. SQLite 3.54.1 is bundled to support read-only access to closed WAL indexes; the schema remains version 5. Set `SIGN_ID` to a signing identity for a consistently signed build; otherwise it is signed ad hoc.

`./script/build_and_run.sh` supports `--debug`, `--logs`, `--telemetry`, and `--verify`. A Codex Run action is provided.

```sh
swift test --disable-sandbox --scratch-path .build-personal -c release
python3 scripts/check-mcp.py 'build.noindex/DigUp Personal.app/Contents/Helpers/digup-mcp'
```

Tests cover read-only storage, WAL backup/adoption, model/schema incompatibility, exclusions before pagination, context access after settings changes, external index refresh, clip validation, and existing upstream retrieval behavior. The optional `DIGUP_ADOPTION_TEST_INDEX` test accepts a disposable copy only; do not point it at your live data.

Developer MCP tests can set `DIGUP_SETTINGS_FILE` to a JSON-encoded `PersonalConfiguration`, and `DIGUP_HELPER` to an explicit helper executable. App launch overrides such as `-defaultsSuite`, `-roots`, `-indexDir`, `-modelsDir`, and `-personalReadOnly YES` isolate UI checks from the real index.

## Credits

DigUp is by Abdur Rahim and remains MIT licensed. Model weights are EmbeddingGemma 2 by Google DeepMind. See [LICENSE](LICENSE), bundled acknowledgements, and [the original README](README.upstream.md).
