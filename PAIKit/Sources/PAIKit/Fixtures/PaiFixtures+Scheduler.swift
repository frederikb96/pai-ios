import Foundation

/// The scheduler's corpus: the task list and the status message every
/// scheduled run is told about. Three tasks cover what the list row draws differently — a
/// cadence task that pushes every notification, one that pushes only blocking ones and stopped
/// at its last run, and a task fired only by hand.
extension PaiFixtures {

    /// `GET /api/scheduler/tasks`.
    public static let schedulerTasks = #"""
        {
          "tasks": [
            {
              "id": "5c0d8e21-7a64-4f0b-9d0e-1b2c3d4e5f60",
              "name": "Nightly backup",
              "enabled": true,
              "environment": "home",
              "working_dir": "/home/frederik",
              "prompt": "Run the nightly borg backup and report only what failed.",
              "append_system_prompt": null,
              "cadence": "10 3 * * *",
              "timezone": "Europe/Berlin",
              "has_gate": false,
              "gate_runtime": null,
              "gate_timeout_seconds": 30,
              "session_policy": "fresh",
              "session_id": null,
              "quiet_period_minutes": 60,
              "notify_on_gate_skip": false,
              "notify_push": "blocking",
              "supervision_enabled": false,
              "supervision_model": null,
              "stopped": true,
              "stopped_reason": "The borg repository refused the lock.",
              "last_fire_at_ms": 1756610000000,
              "last_success_at_ms": 1756520000000,
              "next_fire_at_ms": 1756696200000,
              "created_at_ms": 1754039700000,
              "updated_at_ms": 1756610000000,
              "last_run": {
                "id": "8a1b2c3d-0000-4c1a-8f30-2b7e5c918d71",
                "task_id": "5c0d8e21-7a64-4f0b-9d0e-1b2c3d4e5f60",
                "trigger": "schedule",
                "disposition": "error",
                "reason": "The borg repository refused the lock.",
                "session_id": null,
                "gate_stdout": null,
                "gate_exit_code": null,
                "gate_skipped": false,
                "runtime_warned": false,
                "budget_warned": false,
                "started_at_ms": 1756610000000,
                "finished_at_ms": 1756610060000,
                "notified": true
              }
            },
            {
              "id": "5c0d8e21-7a64-4f0b-9d0e-1b2c3d4e5f61",
              "name": "Grocery sync",
              "enabled": true,
              "environment": "home",
              "working_dir": null,
              "prompt": "Sync the grocery list with the shop and tell me only if something is missing.",
              "append_system_prompt": null,
              "cadence": "0 */6 * * *",
              "timezone": "Europe/Berlin",
              "has_gate": true,
              "gate_runtime": "bun",
              "gate_timeout_seconds": 30,
              "session_policy": "reuse",
              "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619",
              "quiet_period_minutes": 30,
              "notify_on_gate_skip": false,
              "notify_push": "all",
              "max_defer_minutes": 90,
              "deferred_since_ms": 1756600000000,
              "supervision_enabled": true,
              "supervision_model": "sonnet",
              "stopped": false,
              "stopped_reason": null,
              "last_fire_at_ms": 1756598400000,
              "last_success_at_ms": 1756598400000,
              "next_fire_at_ms": 1756620000000,
              "created_at_ms": 1754039700000,
              "updated_at_ms": 1756598400000,
              "last_run": {
                "id": "8a1b2c3d-0000-4c1a-8f30-2b7e5c918d72",
                "task_id": "5c0d8e21-7a64-4f0b-9d0e-1b2c3d4e5f61",
                "trigger": "schedule",
                "disposition": "fired",
                "reason": null,
                "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619",
                "gate_stdout": "1",
                "gate_exit_code": 0,
                "gate_skipped": false,
                "runtime_warned": false,
                "budget_warned": false,
                "started_at_ms": 1756598400000,
                "finished_at_ms": 1756598700000,
                "notified": false
              }
            },
            {
              "id": "5c0d8e21-7a64-4f0b-9d0e-1b2c3d4e5f62",
              "name": "Weekly review",
              "enabled": false,
              "environment": "websearch",
              "working_dir": null,
              "prompt": "Summarise the week from my notes.",
              "append_system_prompt": null,
              "cadence": null,
              "timezone": "Europe/Berlin",
              "has_gate": false,
              "gate_runtime": null,
              "gate_timeout_seconds": 30,
              "session_policy": "one_shot",
              "session_id": null,
              "quiet_period_minutes": 60,
              "supervision_enabled": false,
              "supervision_model": null,
              "stopped": false,
              "stopped_reason": null,
              "last_fire_at_ms": null,
              "last_success_at_ms": null,
              "next_fire_at_ms": null,
              "created_at_ms": 1756000000000,
              "updated_at_ms": 1756000000000
            }
          ],
          "next_offset": null
        }
        """#

    /// `GET /api/status-message` — set, active, with an expiry, so Settings photographs the
    /// editor holding a message rather than an empty field.
    public static let statusMessage = #"""
        {
          "text": "I am travelling until Friday: keep runs short and do not start anything that needs me.",
          "expires_at": "2026-09-05T18:00:00.000000+00:00",
          "active": true,
          "updated_at": "2026-08-31T08:00:00.000000+00:00"
        }
        """#
}
