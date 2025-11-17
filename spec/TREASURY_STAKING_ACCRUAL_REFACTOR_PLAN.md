## Treasury → Staking Accrual Refactor Plan

### Summary

- `LevrStaking_v1.accrueRewards()` already accounts for any ERC20 balance sitting in staking (`src/LevrStaking_v1.sol` lines 243-250).
- `LevrTreasury_v1.applyBoost()` currently gives `LevrStaking_v1` an allowance and asks it to pull tokens via `accrueFromTreasury()` (`src/LevrTreasury_v1.sol` lines 52-62).
- The dedicated `accrueFromTreasury()` hook (`src/LevrStaking_v1.sol` lines 393-415) duplicates the normal accrual path and adds approval complexity without extra protections.
- Goal: remove the redundant hook so boosts are just treasury transfers followed by a permissionless `accrueRewards()` call (which off-chain automation or any EO can trigger).

### Desired End State

1. Treasury sends boost tokens directly to staking via `safeTransfer` (no approvals, no special hook).
2. Staking contract no longer exposes `accrueFromTreasury` in either the contract or interface.
3. Governor boost proposals still route through `Treasury.applyBoost` but now only move funds.
4. Off-chain keepers (or governors) call `accrueRewards(token)` after observing new balances. No protocol requirement to perform the call in the boost transaction.

### Implementation Steps

**1. Interface cleanup**

- Remove `accrueFromTreasury` from `ILevrStaking_v1` and adjust any comments referencing it.
- Update `ILevrTreasury_v1` docstring for `applyBoost` to reflect the transfer-only behavior.

**2. `LevrStaking_v1` changes**

- Delete the `accrueFromTreasury` function and any custom errors or events that only it used (currently reuses shared errors, so no new ones expected).
- Ensure no internal calls remain (search for `accrueFromTreasury` usages).
- Double-check `_availableUnaccountedRewards` still handles deltas correctly when funds are pushed directly.

**3. `LevrTreasury_v1` changes**

- Replace the approval + pull pattern with a direct `safeTransfer` to `project.staking`.
- (Optional) emit an event or reuse existing ones if visibility is desired; otherwise documenting behavior may be enough.
- Decide whether `applyBoost` should also auto-call `accrueRewards(token)` for UX. Given the request, default to transfer-only and rely on off-chain automation; document expectation in comments/spec.

**4. Governance wiring (`LevrGovernor_v1`)**

- No signature changes needed; ensure `_executeProposal` still succeeds when `applyBoost` is transfer-only.
- If tests assert that `applyBoost` triggers accrual immediately, update them to expect deferred accrual.

**5. SDK / tooling touch points**

- Update any TypeScript/SDK helpers that previously invoked `accrueFromTreasury` (search repo for `accrueFromTreasury`).
- Communicate to automation/ops teams that post-boost accrual is now an off-chain responsibility (the action itself remains permissionless).

**6. Documentation**

- Update `spec/USER_FLOWS.md` (staking rewards) and `spec/TESTING.md` (keeper responsibilities) to mention the new flow.
- Add CHANGELOG entry noting the removal of `accrueFromTreasury` and new keeper requirement.

### Testing Plan

**Unit Tests (dev profile)**

- `FOUNDRY_PROFILE=dev forge test --match-path "test/unit/LevrTreasuryV1.t.sol" -vvv`
  - Update/extend tests to ensure `applyBoost` now calls `safeTransfer` and leaves staking with a positive balance while not reverting when `accrueRewards` isn’t invoked.
- `FOUNDRY_PROFILE=dev forge test --match-path "test/unit/LevrStakingV1.t.sol" -vvv`
  - Remove scenarios relying on `accrueFromTreasury`.
  - Add a test where tokens are pushed directly into staking and a third party calls `accrueRewards`.
- `FOUNDRY_PROFILE=dev forge test --match-path "test/unit/LevrStakingV1.GovernanceBoostMidstream.t.sol" -vvv`
  - Ensure midstream boosts still settle correctly after direct transfer + later accrual.

**Integration / e2e**

- `forge test --match-path "test/e2e/LevrV1.Staking.t.sol" -vvv`
  - Simulate a full governor boost execution: proposal → treasury transfer → keeper-triggered `accrueRewards`.

**Regression sweeps**

- Run the whole unit suite once (`FOUNDRY_PROFILE=dev forge test --match-path "test/unit/*.t.sol" -vvv`) to catch any other implicit dependencies.

### Rollout & Monitoring

- Deploy new contracts or upgrade proxies as required (depends on factory model); coordinate with keeper operators so they start calling `accrueRewards`.
- Monitor reward accruals after the change; metrics should show boosts settling only after keepers act.
- Because staking no longer pulls funds, confirm ERC20s with non-standard approvals (e.g., USDT) behave better—this was one motivation for the refactor.

### Open Questions / Follow-ups

- Should `applyBoost` optionally optionally call `accrueRewards` if gas permits? (Default assumption: no, per request.)
- Do we want an event in treasury to signal that accrue is pending for a token?
- Are there any scripts (deployment, simulations) that rely on `accrueFromTreasury` needing updates?
