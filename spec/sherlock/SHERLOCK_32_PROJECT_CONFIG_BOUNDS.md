# Sherlock Audit Issue: Project Config Bounds Bypass

**Date Created:** November 17, 2025  
**Date Validated:** November 17, 2025  
**Status:** ⚠️ **CONFIRMED – HIGH SEVERITY (Fix Required)**  
**Severity:** HIGH (Governance capture / forced proposal execution)  
**Category:** Governance Configuration / Access Control

---

## Executive Summary

- **What happened?** A verified project admin can call `LevrFactory_v1::updateProjectConfig` immediately before a governance cycle flip and push arbitrarily small governance parameters (quorum/approval BPS = 0, voting window = 1 second, etc.).
- **Why is it possible?** `_validateConfig` only checks for zero or >10000 values. There are no lower bounds or change-rate limits for sensitive governance knobs even though the function is callable by a single EOAs (token admins).
- **Impact:** The admin can force any proposal to pass unilaterally by shrinking the participation window and thresholds, undermining all DAO guarantees and enabling treasury drains or hostile parameter changes.
- **Recommended fix:** Introduce immutable guardrails for every overridable field (minimum voting/proposal durations, minimum quorum/approval/minimum quorum bps, minimum submission thresholds, etc.) plus an optional notice period for overrides. Enforce them inside `_validateConfig`.
- **Status:** Root cause confirmed via code review. Needs guardrail implementation + tests.

---

## Table of Contents

1. [Issue Summary](#issue-summary)
2. [Vulnerability Details](#vulnerability-details)
3. [Attack Walkthrough](#attack-walkthrough)
4. [Impact Assessment](#impact-assessment)
5. [Proposed Remediation](#proposed-remediation)
6. [Implementation Plan](#implementation-plan)
7. [Testing Plan](#testing-plan)
8. [Open Questions](#open-questions)
9. [Next Steps](#next-steps)

---

## Issue Summary

Sherlock auditors reported that a protocol admin can force governance outcomes by temporarily trashing the per-project config before a voting cycle flips. Because `updateProjectConfig` can only be called for verified projects, we implicitly promised token holders that we would enforce sane boundaries. Today those boundaries do not exist, so:

1. The admin sets `quorumBps = 0`, `approvalBps = 0`, `votingWindowSeconds = 1`.
2. Waits for the next `cycle increase`.
3. Creates a malicious proposal that instantly meets quorum (0) and approval (0) in one second.
4. Immediately restores the previous config to hide the manipulation.

The DAO loses any meaningful control; governance becomes effectively centralized in the admin EOA.

---

## Vulnerability Details

### Unbounded project overrides

`updateProjectConfig` copies whatever the admin provides into factory storage without clamping it to protocol-level safe values.

```187:215:src/LevrFactory_v1.sol
    function updateProjectConfig(
        address clankerToken,
        ProjectConfig calldata cfg
    ) external override {
        Project storage p = _projects[clankerToken];
        if (p.staking == address(0)) revert ProjectNotFound();
        if (!p.verified) revert ProjectNotVerified();
        if (IClankerToken(clankerToken).admin() != _msgSender()) revert UnauthorizedCaller();

        _updateConfig(
            FactoryConfig(
                protocolFeeBps,
                cfg.streamWindowSeconds,
                protocolTreasury,
                cfg.proposalWindowSeconds,
                cfg.votingWindowSeconds,
                cfg.maxActiveProposals,
                cfg.quorumBps,
                cfg.approvalBps,
                cfg.minSTokenBpsToSubmit,
                cfg.maxProposalAmountBps,
                cfg.minimumQuorumBps
            ),
            clankerToken,
            false
        );
```

### Validation only forbids zeros and >100% BPS

The shared validator is pure, so it cannot pull configurable guardrails from storage and therefore cannot protect against small-but-non-zero values.

```419:438:src/LevrFactory_v1.sol
    function _validateConfig(FactoryConfig memory cfg, bool validateProtocolFee) private pure {
        if (
            cfg.quorumBps > 10000 ||
            cfg.approvalBps > 10000 ||
            cfg.minSTokenBpsToSubmit > 10000 ||
            cfg.maxProposalAmountBps > 10000 ||
            cfg.minimumQuorumBps > 10000
        ) revert InvalidConfig();

        if (validateProtocolFee && cfg.protocolFeeBps > 10000) revert InvalidConfig();

        if (
            cfg.maxActiveProposals == 0 ||
            cfg.proposalWindowSeconds == 0 ||
            cfg.votingWindowSeconds == 0 ||
            cfg.streamWindowSeconds == 0
        ) revert InvalidConfig();
    }
```

Because `quorumBps = 1` and `approvalBps = 1` satisfy the validator, the admin has exact control over all sensitive parameters.

---

## Attack Walkthrough

1. **Preparation**
   - Project is verified, so overrides are allowed.
   - Admin keeps a copy of the original config.

2. **Parameter Collapse**
   - Call `updateProjectConfig` with:
     - `proposalWindowSeconds = 60` (or 1)
     - `votingWindowSeconds = 1`
     - `quorumBps = 0`
     - `approvalBps = 0`
     - `minSTokenBpsToSubmit = 1` (permits microscopic stakes to propose)

3. **Malicious Proposal**
   - Submit proposal that transfers large treasury balance to admin-controlled address.
   - Immediately vote YES (quorum requirement already 0, so even no vote passes).

4. **Execution**
   - With no real voting period, the proposal instantly moves to executable state.
   - Execute the treasury drain.

5. **Cover Up**
   - Restore original config so on-chain data appears “normal”.

No other token holder had time to react, and on-chain governance logs alone do not reveal that parameters were briefly collapsed.

---

## Impact Assessment

- **Severity:** HIGH
- **Type:** Governance capture / treasury theft
- **Blast radius:**
  - All verified projects (current and future)
  - Any module that trusts factory getters for quorum/approval/voting windows
- **Likelihood:** High. Anyone with token admin access (which already exists for operations) can execute this without additional privileges.
- **User impact:** Token holders believe they have voting power, but proposals can be forced through without participation.

---

## Proposed Remediation

1. **Introduce configurable guardrails**
   - Add a `struct ConfigBounds { ... }` storing minimum (and optionally maximum) values per field.
   - Store `ConfigBounds public configBounds;` inside the factory.
   - Provide an `updateConfigBounds(ConfigBounds calldata bounds)` function gated by `onlyOwner`.

2. **Leverage guardrails during validation**
   - Convert `_validateConfig` to `internal view` so it can read `configBounds`.
   - Require:
     - `cfg.proposalWindowSeconds >= configBounds.minProposalWindowSeconds`
     - `cfg.votingWindowSeconds >= configBounds.minVotingWindowSeconds`
     - `cfg.quorumBps >= configBounds.minQuorumBps`
     - `cfg.approvalBps >= configBounds.minApprovalBps`
     - `cfg.minSTokenBpsToSubmit >= configBounds.minMinSTokenBps`
     - `cfg.minimumQuorumBps >= configBounds.minMinimumQuorumBps`
     - `cfg.streamWindowSeconds >= configBounds.minStreamWindowSeconds`
   - Optionally enforce maximums (e.g., `maxActiveProposals <= configBounds.maxActiveProposals`) to keep overrides within reason.

3. **Default guardrail values**
   - Bake in protocol defaults aligned with the recommendation (>= 1 day voting) and allow the owner to update later if governance model evolves.
   - Suggested initial minima:
     - `minProposalWindowSeconds = 6 hours`
     - `minVotingWindowSeconds = 48 hours`
     - `minQuorumBps = 2000` (20%)
     - `minApprovalBps = 5000` (50%)
     - `minMinSTokenBps = 100` (1% supply)
     - `minMinimumQuorumBps = 1000` (10%)

4. **Optional notice period**
   - To further reduce race conditions, track `configPending[project] = {cfg, eta}` and require a timelock (e.g., 24h) before the new config becomes active. This makes surprise collapses impossible.

---

## Implementation Plan

| Step | Description                                                                                                              |
| ---- | ------------------------------------------------------------------------------------------------------------------------ |
| 1    | Define `ConfigBounds` struct + storage variable and initialize it in the constructor with safe defaults.                 |
| 2    | Add `updateConfigBounds(ConfigBounds calldata bounds)` + event so governance can adjust guardrails (owner-only).         |
| 3    | Change `_validateConfig` signature to `internal view` and enforce both upper (<= 10000) and lower (>= guardrail) bounds. |
| 4    | Update `updateConfig` and `updateProjectConfig` call sites to consume the new validator (no other code changes needed).  |
| 5    | (Optional) Introduce per-project config timelock if we want an additional defense-in-depth layer.                        |

---

## Testing Plan

1. **Happy path:** Project admin can still set configs above guardrails.
2. **Lower-bound reverts:** Each guardrail violation reverts with `InvalidConfig`.
3. **Regression:** Existing behavior (factory-level updates, verification, getters) remains unchanged.

Recommended Foundry command:

```bash
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/factory/LevrFactoryConfigBounds.t.sol" -vvv
```

Test cases to add:

- `test_updateProjectConfig_revertsWhenQuorumBelowMin()`
- `test_updateProjectConfig_revertsWhenVotingWindowBelowMin()`
- `test_factoryOwnerCanRaiseBoundsAndExistingConfigsMustRespect()`
- `test_configBounds_canBeUpdatedButNotSetToZero()`

---

## Open Questions

1. Do we also want to cap how frequently a project can update its config (e.g., enforce cooldown)?  
   **Decision:** No. Introducing a cooldown would complicate emergency parameter updates for verified teams without materially reducing the core risk now that guardrails/timelocks exist.
2. Should we allow individual projects to opt into stricter guardrails?  
   **Decision:** No. Guardrails stay uniform at the factory level so integrators can rely on a single set of invariants.

---

## Next Steps

- [ ] Implement guardrail storage + validation changes in `LevrFactory_v1`.
- [ ] Add the bounding tests listed above.
- [ ] Communicate the change to active projects so they know overrides must comply.
- [ ] Consider timelocking project config changes if auditors require stronger guarantees.

---

**Owner:** Protocol Engineering  
**Target Fix Window:** < 1 week (required before audit close-out)
