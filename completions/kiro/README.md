# Kiro CLI / Fig autocomplete spec for cocker

This directory ships a Fig-format autocomplete spec (`cocker.ts`) so users
of [Kiro CLI](https://kiro.dev) (the successor of Fig and Amazon Q for
command line) get inline, descriptive suggestions when typing `cocker`
commands in the terminal — the same kind of popup you see for `git`,
`npm`, `pnpm`, `docker`, etc.

Coverage : every subcommand of `cocker` 1.1+ (run, ps, compose up,
daemon, build, network, volume, secret, config, plugin, buildx, swarm,
stack, service, context, icloud, …) including their flags, repeatable
options, and dynamic generators that query the running daemon for
container / image / network / volume / context names so you get
fuzzy-matchable suggestions instead of having to remember IDs.

---

## Install (local — works in 30 seconds)

```bash
# 1. Clone or update this repo, then drop the spec into Kiro's custom-specs
#    directory. The location depends on which Kiro / Fig build you have :
mkdir -p ~/.fig/autocomplete/build
cp completions/kiro/cocker.ts ~/.fig/autocomplete/build/

# 2. Restart your terminal (or run `kiro restart` if you have the binary
#    on PATH — some Kiro installs ship it under
#    /Applications/Kiro CLI.app/Contents/MacOS/kiro-cli ).
```

After this, typing `cocker` then space + TAB (or just space, depending
on your Kiro setup) should pop the rich-formatted command palette. Try
`cocker compose <space>` — you should see `up / down / ls / logs / ps
/ exec / run / build / pull / watch / …` with one-line descriptions.

> If suggestions don't appear, open the Kiro app menu → Settings →
> Autocomplete and check that the "Custom specs" path matches where
> you copied the file. The default has shifted between Fig 2.x, Fig 3
> and the AWS-rebranded Kiro builds — see Kiro's
> [docs/cli](https://kiro.dev/docs/cli) for the current canonical path.

## Install (compiled `.js` if your Kiro build only accepts compiled specs)

Older Fig versions accept `.ts` directly. Kiro 2.x and later prefer a
compiled `.js`. Compile in one line :

```bash
npx -y @fig/autocomplete-tools compile completions/kiro/cocker.ts \
    --output ~/.fig/autocomplete/build/cocker.js
```

(`npx` will fetch `@fig/autocomplete-tools` on first run and cache it.)

## Why two paths exist

- **Local install** lets you test changes before they ship to anyone
  else. Edit `cocker.ts`, re-copy / re-compile, restart your terminal.
- **Upstream submission** (the Fig autocomplete catalog, now hosted
  under AWS) makes the spec available to every Kiro user without manual
  steps. Once cocker reaches a few hundred users we plan to PR this
  spec there ; until then, the local-install path keeps it discoverable.

## Updating the spec

The spec is hand-written today, but mirrors the Swift `CommandConfiguration`
declarations in `Sources/CockerCLI/Commands/*.swift`. When a command
changes (new flag, renamed subcommand, …), update the matching block in
`cocker.ts` in the same PR. A regression in the spec is shippable — Kiro
just falls back to no suggestions — but the spec is meant to track
reality.

A future improvement could derive the spec automatically from the CLI's
help output ; for now, keep it in sync by hand.

## Reporting an issue

If a command shows wrong / missing flags, open an issue at
https://github.com/gloiiire/cocker/issues with the literal command line
you typed and what you expected to see.
