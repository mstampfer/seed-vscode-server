# seed-vscode-server

Idempotently **pre-seed the VS Code Remote-SSH server** into the modern
(CLI-based) layout, so an air-gapped / proxied / locked-down Linux host can
connect over Remote-SSH **without** the first-connection download that your
network blocks.

## Why

Recent VS Code dropped the old `~/.vscode-server/bin/<commit>/` layout in favor
of `~/.vscode-server/cli/servers/Stable-<commit>/server/` plus a separate CLI
bootstrap binary. On a network that blocks `update.code.visualstudio.com`, the
first connection fails because the server can't download itself. This script
lays the two Microsoft artifacts down at the exact paths the client probes.

## Modern layout

VS Code >= ~1.85 (anything with **no** `~/.vscode-server/bin`):

```
~/.vscode-server/
|-- code-<commit>                           # CLI bootstrap binary (static / musl)
`-- cli/servers/Stable-<commit>/server/     # the REH server (glibc >= 2.28)
    `-- bin/code-server                     # integrity check: `code-server --version`
```

## Requirements

- bash 4+, `tar`, `find`, `install`
- `curl` or `wget` (only for `--download`)
- Target: Linux remote (e.g. RHEL 8.10, glibc >= 2.28), x86_64

## The two artifacts

You supply the artifacts for the **exact commit** your client wants
(Help → About on the client, or the "Using commit id ..." line in the
Remote-SSH output channel):

- **server:** `https://update.code.visualstudio.com/commit:<commit>/server-linux-x64/stable`
- **cli:** `https://update.code.visualstudio.com/commit:<commit>/cli-alpine-x64/stable`

## Typical air-gapped flow

1. On a machine **with** internet (e.g. your Mac), download both tarballs for
   the commit, then `scp` them to the RHEL box.
2. Run this script **on** the RHEL box, as the user who connects over SSH.

## Getting the script onto the host

The script is published as a GitHub Gist. Fetch it through the Gists REST API,
which serves the raw file content as a JSON field rather than as a downloadable
asset — handy when only `api.github.com` is reachable and `raw.githubusercontent.com`
is blocked. Grab the gist id (the hash segment in your gist URL,
`gist.github.com/mstampfer/<GID>`) and pull the file out of the API response
with `jq`:

```sh
GID=<gist_id>   # the hash segment in your gist URL: gist.github.com/mstampfer/<GID>

# with jq:
curl -fsSL "https://api.github.com/gists/$GID" \
  | jq -r '.files["seed-vscode-server.sh"].content' > seed-vscode-server.sh
```

How it works:

- `GET /gists/$GID` returns a JSON document describing the gist; each file lives
  under `.files`, keyed by filename, with its full text in the `.content` field.
- `jq -r '.files["seed-vscode-server.sh"].content'` selects that file and prints
  its raw (`-r`) content, which is redirected into a local
  `seed-vscode-server.sh`.
- `curl -fsSL` fails on HTTP errors (`-f`), stays quiet (`-s`), shows real errors
  (`-S`), and follows redirects (`-L`).

If the host is fully air-gapped (no egress at all), run the command above on a
machine with internet and `scp` the resulting script over alongside the two
VS Code tarballs. Remember to `chmod +x seed-vscode-server.sh` before running it.

## Usage

```sh
# Explicit commit + both tarballs
seed-vscode-server.sh --commit <hash> --server ./server.tgz --cli ./cli.tgz

# Auto-detect commit from a leftover Stable-*.staging dir
seed-vscode-server.sh --server ./server.tgz --cli ./cli.tgz

# Let the host fetch them itself (only if it has egress)
seed-vscode-server.sh --commit <hash> --download
```

| Flag | Description |
| --- | --- |
| `--commit <hash>` | 40-char commit hash (matches client Help → About). If omitted, recovered from a leftover `Stable-*.staging` dir. |
| `--server <path>` | Path to `server-linux-x64` tarball (`.tar.gz`). |
| `--cli <path>` | Path to `cli-alpine-x64` tarball (`.tar.gz`). |
| `--download` | Fetch both from `update.code.visualstudio.com` for `--commit` (only works if this host can reach that domain). |
| `-h`, `--help` | Show help. |

Re-running is safe: if the server + CLI for that commit are already present and
`code-server --version` succeeds, it does nothing.

## License

MIT
