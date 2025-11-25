# LevrTreasury_v1

## Glossary

*   **Governor**: The contract/entity that has the authority to move funds.
*   **Underlying**: The main token of the project (though the treasury can hold anything).

## Overview
`LevrTreasury_v1` is the vault. It is designed to be dumb and secure. It holds the money and only moves it when the Boss (the Governor) says so.

## Architecture
- **Implementation**: `LevrTreasury_v1.sol`
- **Inheritance**: `ERC2771ContextBase`.

## Complex Logic Explained

### 1. Access Control
This contract is intentionally simple.
- It has one modifier: `onlyGovernor`.
- Every critical function is protected by this modifier.
- This ensures that no one—not the factory owner, not the developer—can touch the funds. Only the Governance process (Proposal -> Vote -> Pass) can move them.

## API Reference

### Functions
- `transfer(token, to, amount)`: Sends tokens. Only callable by Governor.

### Events
- `TransferExecuted`: Proof that money moved.

## Errors
- `OnlyGovernor`: Access denied.
