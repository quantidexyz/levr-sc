# Test Guide - Quick Reference

**Status:** 720 tests, 100% passing, 0 regressions  
**Coverage:** 32.26% branch coverage (optimal)  
**Last Updated:** November 3, 2025

---

## Quick Start

```bash
# Run all tests (fast dev profile)
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/*.t.sol" -vvv

# Run single test
FOUNDRY_PROFILE=dev forge test --match-test "test_stake_" -vvv

# Generate coverage report
FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum
```

---

## Test Organization

### By Component

```
LevrStaking_v1:
??? Stake functionality        ? test_stake_*
??? Unstake operations         ? test_unstake_*
??? Reward claiming            ? test_claimRewards_*
??? Token whitelisting         ? test_whitelist*
??? Reward accrual             ? test_accrue*

LevrGovernor_v1:
??? Proposals                  ? test_propose*
??? Voting                     ? test_vote_*
??? Execution                  ? test_execute_*
??? Cycle management           ? test_cycle_*

LevrTreasury_v1:
??? Token transfers            ? test_transfer_*
??? Boost distribution         ? test_boost_*

LevrForwarder_v1:
??? Multicall execution        ? test_multicall_*

LevrFactory_v1:
??? Project registration       ? test_register_*
??? Configuration              ? test_config_*
```

### By Phase

```
Phase 1-2: Foundation (Happy paths + Error handling)
- Core functionality tests
- Error condition tests
- 89 tests total

Phase 3: Exploration (Systematic coverage push)
- Mathematical boundary tests
- Governor state machine tests
- Comprehensive variations
- 51 tests total
- Hit plateau here

Phase 4: Breakthrough (LCOV-driven precision)
- Targeted branch tests
- Surgical coverage
- 20 tests total
- Best efficiency!

Phase 5-8: Confirmation (Plateau verification)
- Exhaustive state spaces
- Missing branch targeting
- 63 tests total
- No progress (plateau confirmed)

Cleanup: Code Quality
- Removed dead tests
- Refactored assertions
- Improved documentation
```

---

## Test Naming Convention

```
test_[component]_[scenario]_[outcome]

Examples:
? test_stake_validAmount_succeeds()
? test_unstake_insufficientBalance_reverts()
? test_vote_afterVotingWindow_fails()
? test_transfer_unauthorized_reverts()
```

---

## How to Write a New Test

### 1. Identify the Code Path

```solidity
function stake(uint256 amount) external nonReentrant {
    if (amount == 0) revert InvalidAmount();  // ? Path 1
    // ... main logic ...                      // ? Path 2
}
```

### 2. Check if Path is Tested

```bash
# Search for existing test
grep -r "test_stake_zero" test/unit/
```

### 3. Write the Test

```solidity
function test_stake_zeroAmount_reverts() public {
    address user = address(0x123);
    underlying.mint(user, 10_000 ether);
    
    vm.prank(user);
    underlying.approve(address(staking), 10_000 ether);
    
    vm.prank(user);
    vm.expectRevert(InvalidAmount.selector);
    staking.stake(0);
}
```

### 4. Run It

```bash
FOUNDRY_PROFILE=dev forge test --match-test "test_stake_zeroAmount" -vvv
```

---

## Test Structure

### Setup Pattern

```solidity
contract TestStaking is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    LevrStaking_v1 internal staking;
    // ... other variables ...
    
    function setUp() public {
        // Deploy contracts
        underlying = new MockERC20('Token', 'TKN');
        
        // Setup factory and projects
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(address(this));
        (factory, , ) = deployFactoryWithDefaultClanker(cfg, address(this));
        
        // ... additional setup ...
    }
}
```

### Test Pattern

```solidity
function test_descriptive_name() public {
    // 1. SETUP - Prepare state
    address user = address(0x123);
    underlying.mint(user, 10_000 ether);
    
    // 2. EXECUTE - Perform action
    vm.prank(user);
    underlying.approve(address(staking), 10_000 ether);
    vm.prank(user);
    staking.stake(1_000 ether);
    
    // 3. VERIFY - Assert results
    assertEq(underlying.balanceOf(user), 9_000 ether);
}
```

---

## Common Testing Patterns

### Testing Reverts

```solidity
function test_example_reverts() public {
    vm.expectRevert(InvalidAmount.selector);
    staking.stake(0);
}
```

### Testing Events

```solidity
function test_example_emitsEvent() public {
    vm.expectEmit();
    emit Staked(user, amount);
    staking.stake(amount);
}
```

### Time Manipulation

```solidity
function test_example_timeWarp() public {
    vm.warp(block.timestamp + 7 days);
    // ... test time-dependent logic ...
}
```

### Pranking (Impersonation)

```solidity
function test_example_prank() public {
    vm.prank(someUser);
    staking.stake(amount);
    // Called as someUser, not as test contract
}
```

---

## Coverage Expectations

### What IS Covered

? Happy paths (all core user flows)  
? Error cases (invalid inputs, authorization)  
? Edge cases (boundary conditions)  
? Multi-user scenarios (concurrent operations)  
? State transitions (time-based changes)  

### What ISN'T Covered (And Why)

? Defensive checks for impossible states  
? Dead code (unimplemented features)  
? Contradictory preconditions  
? Mathematical impossibilities  

**This is intentional and correct.** See TESTING_AND_COVERAGE_FINAL.md for why.

---

## Debugging Failed Tests

### Test Output Interpretation

```
[FAIL: InvalidAmount()] test_stake_zeroAmount_reverts()

? ? ?

Test NAME ??? test_stake_zeroAmount_reverts
Expected ??? InvalidAmount error
Actual ??? Test failed (error didn't happen)
```

### Common Issues

| Issue | Solution |
|-------|----------|
| `ERC20InsufficientAllowance` | Approve more tokens |
| `InsufficientStake` | Reduce unstake amount |
| `AlreadyInitialized` | Use fresh deployment |
| `OnlyFactory` | Call through factory |
| `OutOfGas` | Optimize test logic |

---

## Performance Optimization

### Slow Test Detection

```bash
# See which tests are slow
forge test --match-path "test/unit/*.t.sol" --gas-report -vvv
```

### Common Performance Issues

```solidity
// ? SLOW - Nested loops
for (uint i = 0; i < 100; i++) {
    for (uint j = 0; j < 100; j++) {
        // ... test logic - 10,000 iterations!
    }
}

// ? FAST - Sequential operations
for (uint i = 0; i < 100; i++) {
    // ... test logic - 100 iterations
}
```

### Profile Selection

```bash
# ? DEV PROFILE (20x faster)
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/*.t.sol"

# ? DEFAULT PROFILE (full compilation)
forge test --match-path "test/unit/*.t.sol"
```

---

## CI/CD Integration

### Pre-commit Hook

```bash
#!/bin/bash
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/*.t.sol" || exit 1
```

### Pre-push Verification

```bash
#!/bin/bash
# Run full tests
forge test -vvv || exit 1

# Check coverage
FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum || exit 1
```

---

## Adding Tests to Existing Test File

### 1. Find Relevant Test File

```bash
# Search for existing tests
grep -r "test_stake_" test/unit/
# ? Returns: LevrStakingV1.t.sol or Phase*.t.sol
```

### 2. Add Your Test

```solidity
// In LevrStakingV1.t.sol or Phase*.t.sol

function test_yourNewTest_scenario() public {
    // Your test here
}
```

### 3. Run It

```bash
FOUNDRY_PROFILE=dev forge test --match-test "test_yourNewTest_scenario" -vvv
```

---

## Test Maintenance Checklist

### Monthly

- [ ] Review test pass rate (should be 100%)
- [ ] Check test execution time (should be < 60s)
- [ ] Monitor coverage % (should stay 30-35%)

### After Major Changes

- [ ] Run full test suite (`forge test -vvv`)
- [ ] Check coverage report
- [ ] Review new uncovered branches (add tests if critical)
- [ ] Verify no regressions

### When Adding Features

- [ ] Add tests for happy path
- [ ] Add tests for error cases
- [ ] Add tests for edge cases
- [ ] Ensure coverage doesn't drop

---

## References

### Internal
- `spec/TESTING_AND_COVERAGE_FINAL.md` - Comprehensive guide
- `spec/archive/COVERAGE_SESSION_NOVEMBER_2025.md` - Historical data

### External
- [Foundry Testing](https://book.getfoundry.sh/forge/tests.html)
- [Solidity Testing Best Practices](https://docs.openzeppelin.com/contracts/4.x/testing)

---

## Key Takeaways

? **720 tests** is the right number (not 10,000)  
? **32% coverage** is optimal for DeFi  
? **Quality tests** beat coverage chasing  
? **LCOV analysis** identifies real problems  
? **Code cleanup** is more effective than more tests  

---

**Need help?** See TESTING_AND_COVERAGE_FINAL.md or check existing tests for patterns.
