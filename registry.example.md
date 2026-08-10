# First Mate project registry

Copy this file to `registry.md`, then replace the example rows with projects
available through your Superset CLI.

Fields: `name | mode | yolo | projectId | fork`

- `mode`: `direct-PR` or `local-only`
- `yolo`: `off` by default; `on` permits routine approvals but never destructive,
  irreversible, or security-sensitive actions
- `projectId`: the Superset CLI/cloud project ID, or `-` to resolve it live
- `fork`: optional fork URL for upstream contributions

<!-- registry:begin -->
example-app | direct-PR | off | -
internal-tool | local-only | off | -
upstream-project | direct-PR | off | - | git@github.com:your-name/upstream-project.git
<!-- registry:end -->
