# eISY Insteon SmartThings Edge Driver

This package contains a local SmartThings Edge driver for Universal Devices eISY / IoX controllers with Insteon nodes.

## What It Does

- Creates one `eISY Controller` bridge device during SmartThings discovery.
- Adds a `Scan for devices` button on the `eISY Controller` device that scans eISY and creates supported child devices.
- Uses controller preferences for eISY host, protocol, port, username, password, ignored node patterns, and optional scene IDs.
- Reads eISY nodes from `/rest/nodes` and status from `/rest/status`.
- Auto-creates supported Insteon child devices:
  - switches
  - dimmers
  - keypads as multi-component devices
  - fan controllers
  - outlets
  - motion sensors
  - contact sensors
  - IOLinc as a relay plus sensor multi-component device
- Skips non-Insteon eISY nodes, including node-server, Matter, Z-Wave, and Zigbee nodes.
- Splits FanLinc modules into separate SmartThings devices for the light dimmer and fan motor.
- Keypad secondary buttons display their eISY names and current on/off status with a read-only custom status capability.
- Adds opt-in ISY scenes as switch child devices from a configured scene ID list.
- Sends local commands through `/rest/nodes/<node>/cmd/...`.
- Uses a plain-HTTP `/rest/subscribe` WebSocket connection for live updates. Automatic polling fallback is disabled to protect v3 hubs with large Insteon installations.

## Install And Test

1. Enroll and install the driver at https://bestow-regional.api.smartthings.com/invite/d429GWDwQbjo

2. In the SmartThings app, run nearby device discovery. The driver creates `eISY Controller`.

3. Open the controller device settings and enter:

   - eISY host or IP (IP address works best)
   - protocol (HTTP is faster and uses websockets)
   - port (80)
   - username (your eISY username, same as what you use to login to the eISY Admin Console)
   - password
   - ISY scene IDs (optional comma-separated scene/group IDs to expose in SmartThings)

4. Tap `Scan for devices` on the controller, or refresh the controller. Supported Insteon nodes should appear as child devices.

5. To add selected ISY scenes, enter only the desired scene IDs in `ISY scene IDs`, then tap `Add Scenes from ISY` on the controller. The driver validates the IDs against `/rest/nodes` and creates one switch child device for each matching ISY scene.

## Notes

- eISY/IoX must be reachable from the SmartThings hub on the local network.
- HTTPS REST calls are supported when the hub runtime exposes `ssl.https`.
- The WebSocket subscriber currently supports plain HTTP. HTTPS configurations can still use manual scan and refresh, but they do not receive live WebSocket updates.
- Node classification is heuristic because eISY node metadata varies by device generation and naming. Use `ignoredNodes` to skip unwanted nodes.
- Scenes are opt-in because SmartThings Edge device presentations do not provide a reliable local dynamic picker populated from eISY. Remove a scene from SmartThings by deleting its child device; it will not be recreated unless `Add Scenes from ISY` is tapped again with that scene ID configured.
- Scene status is best-effort. Commands are sent directly to the ISY scene/group, and WebSocket `ST` updates are used when the ISY emits them.
- Programs are intentionally out of scope.
