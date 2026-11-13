# Skills

A skill is a directory holding a `SKILL.md`, whose frontmatter names it and says
in one line what it is for:

```markdown
---
name: release
description: how a release is cut here
---

Run the tests, tag, then push.
```

Searched, in order: `.agents/skills` and `.claude/skills` under the project,
whatever [`skill_paths`](configuration.md) names, then the same pair under
`$HOME`. Skills written for other harnesses work unchanged.

Only the name and description reach the model unasked - it loads the rest when
one applies, or you run it yourself with `/release`. `synth skills` lists what
was found and every directory that was searched.
