#!/usr/bin/env bash
# Authority boundary adapted from kunchenguid/firstmate#518 for Superset.
# Validation/gate agents may inspect first-mate, but must never dispatch, steer,
# recover, or retire the live fleet. Call fm_refuse_gate_agent before mutation.

fm_is_gate_agent() {
  [ -n "${NO_MISTAKES_GATE:-}" ] ||
    [ -n "${NO_MISTAKES_GATE_AGENT:-}" ] ||
    [ -n "${AXI_GATE_AGENT:-}" ]
}

fm_refuse_gate_agent() { # <operation>
  if fm_is_gate_agent; then
    echo "error: refusing first-mate $1 from a no-mistakes gate agent; gate agents are read-only observers of the fleet" >&2
    return 3
  fi
}
