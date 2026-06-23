# Graph Report - Codex Status Bar  (2026-06-23)

## Corpus Check
- 13 files · ~10,087 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 146 nodes · 179 edges · 13 communities (11 shown, 2 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `bd6f20bd`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 4|Community 4]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 7|Community 7]]
- [[_COMMUNITY_Community 8|Community 8]]
- [[_COMMUNITY_Community 9|Community 9]]
- [[_COMMUNITY_Community 10|Community 10]]
- [[_COMMUNITY_Community 11|Community 11]]

## God Nodes (most connected - your core abstractions)
1. `Codex Status Bar` - 10 edges
2. `addThreadSection()` - 8 edges
3. `TransitionSpeed` - 7 edges
4. `hooks` - 7 edges
5. `codexContextMenu()` - 6 edges
6. `run()` - 6 edges
7. `normalizeSnapshot()` - 5 edges
8. `main()` - 5 edges
9. `SessionStatus` - 4 edges
10. `String` - 4 edges

## Surprising Connections (you probably didn't know these)
- None detected - all connections are within the same source files.

## Import Cycles
- None detected.

## Communities (13 total, 2 thin omitted)

### Community 0 - "Community 0"
Cohesion: 0.13
Nodes (24): Any, Bool, Date, Int, NSMenu, NSMenuItem, NSStatusBarButton, RecentThread (+16 more)

### Community 1 - "Community 1"
Cohesion: 0.13
Nodes (18): addMatched(), addUnmatched(), appPath, appPathDest, cmd(), config, detectAppPath(), fs (+10 more)

### Community 2 - "Community 2"
Cohesion: 0.17
Nodes (18): assistantMessageFromRecord(), compactText(), dir, fs, lastAssistantMessageFromTranscript(), needsUserInput(), os, path (+10 more)

### Community 3 - "Community 3"
Cohesion: 0.19
Nodes (16): activeAccountEmail(), authPath, cachePath, callAppServer(), chooseRateLimit(), cp, fs, main() (+8 more)

### Community 4 - "Community 4"
Cohesion: 0.14
Nodes (7): assert, cp, fs, os, path, repo, update

### Community 5 - "Community 5"
Cohesion: 0.22
Nodes (10): appPathFile, cp, dir, fs, os, path, run(), running() (+2 more)

### Community 6 - "Community 6"
Cohesion: 0.18
Nodes (10): Build From Source, Codex Status Bar, How It Works, Install, License, Quota Sources, Requirements, Uninstall (+2 more)

### Community 7 - "Community 7"
Cohesion: 0.25
Nodes (7): hooks, PermissionRequest, PostToolUse, PreToolUse, SessionStart, Stop, UserPromptSubmit

### Community 8 - "Community 8"
Cohesion: 0.25
Nodes (7): config, cp, fs, hooksPath, marker, os, path

### Community 9 - "Community 9"
Cohesion: 0.33
Nodes (5): description, homepage, license, name, version

## Knowledge Gaps
- **73 isolated node(s):** `name`, `description`, `version`, `homepage`, `license` (+68 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What connects `name`, `description`, `version` to the rest of the system?**
  _73 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.12535612535612536 - nodes in this community are weakly interconnected._
- **Should `Community 1` be split into smaller, more focused modules?**
  _Cohesion score 0.13450292397660818 - nodes in this community are weakly interconnected._
- **Should `Community 4` be split into smaller, more focused modules?**
  _Cohesion score 0.14285714285714285 - nodes in this community are weakly interconnected._