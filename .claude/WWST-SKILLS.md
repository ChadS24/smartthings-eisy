# SmartThings WWST Agent Skills

`.claude/skills/` holds an unmodified copy of the SmartThings Developer AI Skills from
[SmartThingsCommunity/wwst-skills](https://github.com/SmartThingsCommunity/wwst-skills).
Claude Code loads them automatically in sessions opened in this repository.

| Field | Value |
| --- | --- |
| Upstream tag | `release/v0.2.0` |
| Upstream commit | `26a7bdb39f1c273d2bb4d1ce39ff3438a752970b` |
| Upstream `skills/` tree | `d6238f5e340adb17661b3c9ea202da4f6c00a030` |

| Skill | Covers |
| --- | --- |
| `smartthings-hub-connected-developer` | WWST certification for Zigbee, Matter, and Z-Wave hub-connected products |
| `smartthings-cloud-connected-developer` | ST-Schema (Schema App) integrations, org setup through certification |
| `smartthings-app-to-app-linking-developer` | App-to-App account linking for Schema Apps on Android and iOS |
| `smartthings-direct-connected-device-sdk-c-developer` | Direct Connected devices built on the SmartThings Device SDK for C |
| `smartthings-device-onboarding-qr` | Onboarding QR code requirements by integration type |

None of them targets LAN Edge drivers like this one, so they mostly help with SmartThings
platform questions (capabilities, profiles, Developer Console, certification), not the eISY code.

## Notes

- Upstream has no LICENSE file. These files are copied following the upstream README's install
  instructions, and all rights stay with their authors.
- `.claude/skills/` must contain only the upstream skills, so the tree hash above stays checkable.
  Keep local notes here, outside that directory.
- Skills are instructions Claude follows. Review the upstream diff before every update.

## Verify

After the skills are committed, this prints the upstream `skills/` tree hash listed above:

```bash
git rev-parse HEAD:.claude/skills
```

## Update

Replace `vX.Y.Z` with the new release, review the diff, then refresh the copy and the hashes above:

```bash
git clone https://github.com/SmartThingsCommunity/wwst-skills /tmp/wwst-skills
git -C /tmp/wwst-skills diff release/v0.2.0 release/vX.Y.Z -- skills
rm -rf .claude/skills && mkdir .claude/skills
git -C /tmp/wwst-skills archive release/vX.Y.Z:skills | tar -x -C .claude/skills
git -C /tmp/wwst-skills rev-parse release/vX.Y.Z release/vX.Y.Z:skills
```

## Remove

Delete `.claude/skills/` and this file.
